#!/usr/bin/env bash
# 秘密検知ゲート（tools/secret_scan.py + フック配線）の回帰テスト（Issue #678）
#
# 検証する不変条件:
#   1. ファイル名ルール（.env / *.pem / service-account*.json / id_rsa_*）と内容ルール（トークン・鍵）を検知する（exit 1）
#   2. テンプレート（.env.example）・プレースホルダ・行内 secret-scan:ignore・許可リスト glob は検知しない（exit 0）
#   3. git pre-commit フック（install_git_hooks.sh 導入）が秘密入りのコミットを中断し、作業ツリーは壊さない
#   4. 本ベース由来でない既存 pre-commit は上書きしない
#   5. pre-tool-use-router.sh が `git commit`（ステージ済み・`git -C <他リポジトリ>` / 最後の `cd` を追随）と
#      mcp__github__push_files（tool_input）を **exit 2 で** ブロックし、`--no-verify` / `-n` / `-c core.hooksPath`
#      （継続行・クォート種混在を含む）と Contents API 直叩き（gh api / curl の各形）もブロックする。
#      exit 1（フック自体の異常終了 = 非ブロック）を「ブロック」と誤判定しない
#   6. pre-git-push-check.sh が未 push コミット中の秘密で push をブロックし、取り除けば通す。
#      upstream も origin/<default> も無い初回 push でも検査する（空ツリー基準）。スキャナ実行エラー（exit 2）は fail-closed。
#      push より後ろの `cd` は無視する
#   7. 自動保全コミット（stop-slack-notify.sh）は秘密ファイルを除外してそれ以外を保全し、秘密は作業ツリーに残る。
#      差し戻し猶予中のスナップショット（GIT_INDEX_FILE 経路・refs/claude-wip）でも秘密を除外する
#   8. CLAUDE_BASE_DISABLE_SECRET_SCAN=1 で全層が無効化できる（脱出ハッチ）
#   9. self_review_check.py の PR 前ゲートは検知（exit 1）と実行エラー（exit 2）の両方で Error を返す（fail-closed）
#  10. 秘密系ファイル名の語リストが secret_scan.py と pre-tool-use-router.sh で一致している（片側だけの更新を検出）
#  11. github_push_helper.py はファイル内容・コミットメッセージのどちらに秘密があっても送信しない
#
# 使い方: bash tools/test_secret_scan.sh
# 終了コード: 0 = 全 PASS / 1 = 1 件以上 FAIL
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test_harness.sh
source "$REPO_ROOT/tools/lib/test_harness.sh"
SCANNER="$REPO_ROOT/tools/secret_scan.py"
ROUTER="$REPO_ROOT/.claude/hooks/pre-tool-use-router.sh"
PUSH_HOOK="$REPO_ROOT/.claude/hooks/pre-git-push-check.sh"
STOP_HOOK="$REPO_ROOT/.claude/hooks/stop-slack-notify.sh"
PUSH_HELPER="$REPO_ROOT/tools/github_push_helper.py"
for f in "$SCANNER" "$ROUTER" "$PUSH_HOOK" "$STOP_HOOK" "$PUSH_HELPER"; do
  [ -f "$f" ] || { echo "FATAL: 見つかりません: $f"; exit 1; }
done
# 後段の作業領域ガードは本テストの関心外（cwd 外の一時リポジトリで動かすため）
export CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1
unset CLAUDE_BASE_DISABLE_SECRET_SCAN

# 秘密は文字列連結で組み立てる（このテストファイル自身がスキャナに掛からないようにするため）
GH_TOKEN_FAKE="ghp_$(printf 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8')"
PEM_HEADER="-----BEGIN $(printf 'RSA PRIVATE KEY')-----"

setup_repo() {
  WORK=$(mktemp -d)
  init_tmp_git_repo "$WORK"
  # フックが参照する配布物を一時リポジトリへ置く（tools/ と .claude/hooks/ の実体）
  mkdir -p "$WORK/repo/tools" "$WORK/repo/.claude/hooks/lib"
  cp "$SCANNER" "$REPO_ROOT/tools/install_git_hooks.sh" "$WORK/repo/tools/"
  cp "$REPO_ROOT/.claude/hooks/git-pre-commit.sh" "$WORK/repo/.claude/hooks/"
  cp "$REPO_ROOT/.claude/hooks/lib/secret_scan.sh" "$WORK/repo/.claude/hooks/lib/"
  echo "base" > "$WORK/repo/base.txt"
  git -C "$WORK/repo" add -A
  git -C "$WORK/repo" commit --quiet -m "base"
  git -C "$WORK/repo" push --quiet -u origin main 2>/dev/null
  git -C "$WORK/repo" checkout --quiet -b feat/test
  git -C "$WORK/repo" push --quiet -u origin feat/test 2>/dev/null
}
# scan <args...>: 終了コードをそのまま返す（1 = 検知 / 0 = クリーン / 2 = 実行エラー を区別して検証する）
scan() { ( cd "$WORK/repo" && python3 tools/secret_scan.py "$@" >/dev/null 2>&1 ); }
scan_rc() { scan "$@"; echo $?; }
# router_rc <json>: フックの終了コード（2 = ブロック / 0 = 許可 / それ以外 = フック自体の異常）
router_rc() { ( cd "$WORK/repo" && printf '%s' "$1" | bash "$ROUTER" >/dev/null 2>&1 ); echo $?; }
push_rc() { ( cd "$WORK/repo" && bash_cmd_json "$1" | bash "$PUSH_HOOK" >/dev/null 2>&1 ); echo $?; }
bash_cmd_json() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
commit_count() { git -C "$WORK/repo" rev-list HEAD --count 2>/dev/null || echo 0; }
expect_block() { [ "$(router_rc "$(bash_cmd_json "$1")")" -eq 2 ] && report ok "$2" || report ng "$3"; }
expect_allow() { [ "$(router_rc "$(bash_cmd_json "$1")")" -eq 0 ] && report ok "$2" || report ng "$3"; }

# ── 1/2: スキャナ単体（--staged / --paths / 許可リスト）──
echo "[1/2] スキャナのファイル名・内容ルールと抑制"
setup_repo
( cd "$WORK/repo" && echo "SECRET=1" > .env && git add .env )
[ "$(scan_rc --staged)" -eq 1 ] && report ok ".env（ファイル名ルール）を検知する（exit 1）" || report ng ".env をステージしても検知しない"
git -C "$WORK/repo" reset -q
( cd "$WORK/repo" && rm -f .env && echo "SECRET=xxx" > .env.example && git add .env.example )
[ "$(scan_rc --staged)" -eq 0 ] && report ok ".env.example（テンプレート）は検知しない" || report ng ".env.example を誤検知した"
git -C "$WORK/repo" reset -q
( cd "$WORK/repo" && rm -f .env.example && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > app.py && git add app.py )
[ "$(scan_rc --staged)" -eq 1 ] && report ok "GitHub トークン（内容ルール）を検知する（exit 1）" || report ng "GitHub トークンの追加行を検知しない"
( cd "$WORK/repo" && printf '++ nested = "%s"\n' "$GH_TOKEN_FAKE" > app.py && git add app.py )
[ "$(scan_rc --staged)" -eq 1 ] && report ok "内容が '++ ' で始まる追加行（diff 上は '+++ '）も検知する" || report ng "'+++ ' 始まりの追加行をヘッダと誤認して見逃した"
( cd "$WORK/repo" && printf 'token = "%s"  # secret-scan:ignore\n' "$GH_TOKEN_FAKE" > app.py && git add app.py )
[ "$(scan_rc --staged)" -eq 0 ] && report ok "行内 secret-scan:ignore で抑制できる" || report ng "行内 ignore が効かない"
( cd "$WORK/repo" && printf 'api_key = "your-api-key-here-000"\npassword = os.environ["PASSWORD"]\n' > app.py && git add app.py )
[ "$(scan_rc --staged)" -eq 0 ] && report ok "プレースホルダ・環境変数参照は検知しない" || report ng "プレースホルダを誤検知した"
( cd "$WORK/repo" && mkdir -p tests/fixtures && printf '%s\n' "$PEM_HEADER" > tests/fixtures/fake.pem && git add tests/fixtures )
[ "$(scan_rc --staged)" -eq 1 ] && report ok "秘密鍵ブロック + *.pem を検知する" || report ng "テストフィクスチャの秘密鍵を検知しない"
( cd "$WORK/repo" && mkdir -p config && echo "tests/fixtures/*" > config/secret_scan_allowlist.txt )
[ "$(scan_rc --staged)" -eq 0 ] && report ok "config/secret_scan_allowlist.txt の glob で除外できる" || report ng "許可リストが効かない"
( cd "$WORK/repo" && rm -rf config tests && git reset -q && rm -f app.py )
mkdir -p "$WORK/repo/secrets"; echo '{}' > "$WORK/repo/secrets/gcp-service-account.json"; echo "fake" > "$WORK/repo/id_rsa_backup"
[ "$(scan_rc --paths secrets/gcp-service-account.json id_rsa_backup)" -eq 1 ] && report ok "service-account*.json / id_rsa_*（#592 の実例と同型）を検知する" || report ng "service-account / id_rsa_* を検知しない"
rm -rf "$WORK/repo/secrets" "$WORK/repo/id_rsa_backup"
[ "$(scan_rc --base nonexistent-ref)" -eq 2 ] && report ok "解決できない基準 ref は実行エラー（exit 2）として区別される" || report ng "解決できない基準 ref が exit 2 にならない"

# ── 10: 語リストの一致（py / sh の片側だけ更新する退行を検出）──
echo "[10] 秘密系ファイル名の語リストが secret_scan.py と pre-tool-use-router.sh で一致"
_py_words=$(grep -oE '\(git-credentials\|[a-z0-9_|?-]+\)' "$SCANNER" | head -1)
_sh_words=$(grep -oE '\(git-credentials\|[a-z0-9_|?-]+\)' "$ROUTER" | head -1)
[ -n "$_py_words" ] && [ "$_py_words" = "$_sh_words" ] \
  && report ok "語リストが一致: $_py_words" \
  || report ng "語リストが不一致（py: ${_py_words:-取得失敗} / sh: ${_sh_words:-取得失敗}）"

# ── 3/4/8: git pre-commit フック ──
echo "[3/4/8] git pre-commit フックの導入とコミット中断"
( cd "$WORK/repo" && bash tools/install_git_hooks.sh >/dev/null 2>&1 )
grep -q 'claude-code-base:secret-scan' "$WORK/repo/.git/hooks/pre-commit" 2>/dev/null \
  && report ok "install_git_hooks.sh が .git/hooks/pre-commit を導入した" \
  || report ng "pre-commit が導入されていない"
( cd "$WORK/repo" && bash tools/install_git_hooks.sh >/dev/null 2>&1 )
grep -q 'claude-code-base:secret-scan' "$WORK/repo/.git/hooks/pre-commit" 2>/dev/null \
  && report ok "再実行しても壊れない（冪等）" || report ng "再実行で pre-commit が壊れた"
_before=$(commit_count)
( cd "$WORK/repo" && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > leak.py && git add -A && git commit -q -m "leak" >/dev/null 2>&1 )
[ "$(commit_count)" -eq "$_before" ] && report ok "秘密入りのコミットを pre-commit が中断した" || report ng "秘密入りのコミットが通った"
[ -f "$WORK/repo/leak.py" ] && report ok "中断後も作業ツリーのファイルは残っている" || report ng "作業ツリーのファイルが消えた"
( cd "$WORK/repo" && CLAUDE_BASE_DISABLE_SECRET_SCAN=1 git commit -q -m "leak (escape hatch)" >/dev/null 2>&1 )
[ "$(commit_count)" -eq $((_before + 1)) ] && report ok "CLAUDE_BASE_DISABLE_SECRET_SCAN=1 で通せる（脱出ハッチ）" || report ng "脱出ハッチが効かない"
git -C "$WORK/repo" reset -q --hard HEAD~1
rm -f "$WORK/repo/leak.py"
printf '#!/bin/sh\necho husky\n' > "$WORK/repo/.git/hooks/pre-commit"
( cd "$WORK/repo" && bash tools/install_git_hooks.sh >/dev/null 2>&1 )
grep -q 'husky' "$WORK/repo/.git/hooks/pre-commit" && report ok "本ベース由来でない既存 pre-commit を上書きしない" || report ng "既存 pre-commit を上書きした"
rm -f "$WORK/repo/.git/hooks/pre-commit"

# ── 5: pre-tool-use-router.sh ──
echo "[5] PreToolUse ルーターのブロック（exit 2 のみをブロックと見なす）"
( cd "$WORK/repo" && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > leak.py && git add leak.py )
expect_block 'git commit -m "add feature"' "git commit（ステージ済みに秘密）を exit 2 でブロックする" "ステージ済み秘密のある git commit を exit 2 でブロックしない"
git -C "$WORK/repo" reset -q; rm -f "$WORK/repo/leak.py"
expect_allow 'git commit -m "clean"' "秘密が無ければ git commit を通す（exit 0）" "秘密が無いのに git commit を通さない"
OTHER="$WORK/other"; git init --quiet "$OTHER"; git -C "$OTHER" config user.email t@e.com; git -C "$OTHER" config user.name t
( cd "$OTHER" && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > leak.py && git add leak.py )
expect_block "git -C $OTHER commit -m leak" "git -C <別リポジトリ> commit（そちらに秘密）をブロックする" "git -C <別リポジトリ> commit の秘密を通した"
expect_block "cd $OTHER && git commit -m leak" "cd <別リポジトリ> && git commit をブロックする" "cd <別リポジトリ> && git commit の秘密を通した"
DECOY="$WORK/decoy"; git init --quiet "$DECOY"
expect_block "cd $DECOY && cd $OTHER && git commit -m leak" "複数の cd は最後の cd（実際の実行先）を検査する" "最初の cd（おとり）を検査して秘密を通した"
expect_block 'git add -A && git commit --no-verify -m x' "git commit --no-verify をブロックする" "--no-verify を通した"
expect_block 'git commit -nm x' "git commit -n（結合フラグ）をブロックする" "-n（結合フラグ）を通した"
expect_block 'git -c core.hooksPath=/dev/null commit -m x' "-c core.hooksPath=… をブロックする" "core.hooksPath 上書きを通した"
expect_block "$(printf 'git add -A && git commit \\\n  --no-verify -m x')" "継続行（バックスラッシュ改行）に逃がした --no-verify もブロックする" "継続行の --no-verify を通した"
expect_block "git commit -m 'say \"part1' --no-verify -m 'part2\"'" "クォート種が交互でも実引数の --no-verify をブロックする" "クォート種混在で --no-verify が消えて通した"
expect_allow 'git commit -m "note: --no-verify は禁止"' "メッセージ中の文言では誤ブロックしない" "コミットメッセージ中の --no-verify を誤検知した"
expect_allow 'git commit --amend --no-edit' "--amend / --no-edit を誤ブロックしない" "--amend / --no-edit を誤検知した"
expect_block 'gh api repos/o/r/contents/x.json --method PUT -f message=m -f content=abc' "gh api …/contents/ PUT をブロックする" "gh api contents PUT を通した"
expect_block 'curl --request PUT https://api.github.com/repos/o/r/contents/x -d @payload.json' "curl --request PUT …/contents/ をブロックする" "curl --request PUT を通した"
expect_block 'curl -X put https://api.github.com/repos/o/r/contents/x -d @payload.json' "curl -X put（小文字）をブロックする" "小文字 put を通した"
expect_block 'curl -T body.json https://api.github.com/repos/o/r/contents/x' "curl -T（暗黙 PUT）をブロックする" "curl -T を通した"
expect_allow 'gh api repos/o/r/contents/x.json' "gh api contents GET は通す" "gh api contents の読み取りを誤ブロックした"
expect_allow 'curl -s https://api.github.com/repos/o/r/contents/x' "curl GET は通す" "curl GET を誤ブロックした"
_pf=$(jq -nc --arg t "$GH_TOKEN_FAKE" '{tool_name:"mcp__github__push_files",tool_input:{owner:"o",repo:"r",branch:"b",message:"m",files:[{path:"a.txt",content:("x=" + $t)}]}}')
[ "$(router_rc "$_pf")" -eq 2 ] && report ok "mcp__github__push_files（tool_input に秘密）を exit 2 でブロックする" || report ng "push_files の秘密入り内容を exit 2 でブロックしない"
_pf=$(jq -nc '{tool_name:"mcp__github__create_or_update_file",tool_input:{owner:"o",repo:"r",branch:"b",message:"m",path:"docs/a.md",content:"hello"}}')
[ "$(router_rc "$_pf")" -eq 0 ] && report ok "秘密が無ければ create_or_update_file を通す（exit 0）" || report ng "秘密が無いのに create_or_update_file を通さない"

# ── 6: pre-git-push-check.sh ──
echo "[6] push 前の未 push 差分検査"
( cd "$WORK/repo" && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > leak.py && git add leak.py && git commit -q --no-verify -m "leak" )
[ "$(scan_rc --unpushed)" -eq 1 ] && report ok "--unpushed が未 push コミット中の秘密を検知する" || report ng "--unpushed が秘密を検知しない"
[ "$(scan_rc --base main)" -eq 1 ] && report ok "--base main（PR 前ゲート相当）が秘密を検知する" || report ng "--base main が秘密を検知しない"
[ "$(push_rc 'git push -u origin feat/test')" -eq 2 ] && report ok "pre-git-push-check.sh が秘密入りコミットの push を exit 2 でブロックする" || report ng "秘密入りコミットの push を exit 2 でブロックしない"
[ "$(push_rc "git push -u origin feat/test && cd $DECOY")" -eq 2 ] && report ok "push の後ろの cd は無視して cwd のリポジトリを検査する" || report ng "push 後の cd に釣られて cwd の秘密を通した"
git -C "$WORK/repo" reset -q --hard HEAD~1
[ "$(push_rc 'git push -u origin feat/test')" -eq 0 ] && report ok "秘密を取り除けば push を通す（exit 0）" || report ng "秘密を取り除いても push を通さない"
( cd "$OTHER" && git commit -q --no-verify -m leak && git remote add origin "$WORK/remote.git" )
[ "$(push_rc "git -C $OTHER push -u origin feat/other")" -eq 2 ] && report ok "git -C <別リポジトリ> push（そちらに秘密）をブロックする" || report ng "git -C <別リポジトリ> push の秘密を通した"
FRESH="$WORK/fresh"; git init --quiet "$FRESH"; git -C "$FRESH" config user.email t@e.com; git -C "$FRESH" config user.name t
mkdir -p "$FRESH/tools"; cp "$SCANNER" "$FRESH/tools/"
( cd "$FRESH" && git remote add origin "$WORK/remote.git" && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > leak.py && git add -A && git commit -q --no-verify -m first )
( cd "$FRESH" && python3 tools/secret_scan.py --unpushed >/dev/null 2>&1 ); _rc=$?
[ "$_rc" -eq 1 ] && report ok "初回 push（基準 ref なし）でも --unpushed が全ファイルを検査して検知する（fail-open にしない）" || report ng "初回 push で --unpushed が検査をスキップした（exit=$_rc）"
# スキャナが実行エラー（exit 2）を返すとき、push 前検査は fail-closed でブロックする
cp "$WORK/repo/tools/secret_scan.py" "$WORK/scanner.bak"
printf 'import sys\nsys.exit(2)\n' > "$WORK/repo/tools/secret_scan.py"
[ "$(push_rc 'git push -u origin feat/test')" -eq 2 ] && report ok "スキャナ実行エラー（exit 2）でも push をブロックする（fail-closed）" || report ng "スキャナ実行エラーで push を通した（fail-open）"
cp "$WORK/scanner.bak" "$WORK/repo/tools/secret_scan.py"

# ── 9: self_review_check.py の PR 前ゲート ──
echo "[9] PR 前ゲート（self_review_check.secret_scan_errors）"
( cd "$WORK/repo" && printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > leak.py && git add leak.py && git commit -q --no-verify -m "leak" )
_n=$(cd "$WORK/repo" && PYTHONPATH="$REPO_ROOT/tools" python3 -c "import self_review_check as s; print(len(s.secret_scan_errors()))" 2>/dev/null)
[ "${_n:-0}" -ge 1 ] && report ok "秘密入りコミットで Error を返す" || report ng "秘密入りコミットでも Error を返さない（n=${_n:-?}）"
git -C "$WORK/repo" update-ref -d refs/remotes/origin/main
_n=$(cd "$WORK/repo" && PYTHONPATH="$REPO_ROOT/tools" python3 -c "import self_review_check as s; print(len(s.secret_scan_errors()))" 2>/dev/null)
[ "${_n:-0}" -ge 1 ] && report ok "基準ブランチを解決できないとき（exit 2）も Error を返す（fail-closed）" || report ng "実行エラーを検知なし扱いにした（n=${_n:-?}）"
git -C "$WORK/repo" fetch -q origin main 2>/dev/null
git -C "$WORK/repo" reset -q --hard HEAD~1

# ── 11: github_push_helper.py（REST フォールバック）の送信前検査 ──
echo "[11] github_push_helper.py の送信前検査（ネットワークに到達する前に止まる）"
echo "safe" > "$WORK/repo/safe.txt"
( cd "$WORK/repo" && GH_TOKEN=dummy python3 "$PUSH_HELPER" --path safe.txt --branch feat/x --repo o/r --message "token = '$GH_TOKEN_FAKE'" >/dev/null 2>&1 ); _rc=$?
[ "$_rc" -eq 1 ] && report ok "コミットメッセージに秘密があれば送信しない（exit 1）" || report ng "メッセージ中の秘密を検査せず送信に進んだ（exit=$_rc）"
printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > "$WORK/repo/leak.txt"
( cd "$WORK/repo" && GH_TOKEN=dummy python3 "$PUSH_HELPER" --path leak.txt --branch feat/x --repo o/r --message "ok" >/dev/null 2>&1 ); _rc=$?
[ "$_rc" -eq 1 ] && report ok "ファイル内容に秘密があれば送信しない（exit 1）" || report ng "ファイル内容の秘密を検査せず送信に進んだ（exit=$_rc）"
rm -f "$WORK/repo/safe.txt" "$WORK/repo/leak.txt"

# ── 7: 自動保全コミット（stop-slack-notify.sh）は秘密を除外して保全する ──
echo "[7] 自動保全コミットからの除外"
( cd "$WORK/repo" && bash tools/install_git_hooks.sh >/dev/null 2>&1 )
echo "work" > "$WORK/repo/work.txt"
printf 'token = "%s"\n' "$GH_TOKEN_FAKE" > "$WORK/repo/leak.py"
echo "SECRET=1" > "$WORK/repo/.env"
_before=$(commit_count)
( cd "$WORK/repo" && CLAUDE_CODE_REMOTE=true CLAUDE_STOP_GIT_CHECK_BLOCKED=1 \
    bash "$STOP_HOOK" <<< '{"session_id":"sess-D","stop_hook_active":"false"}' >/dev/null 2>&1 )
_snap=$(git -C "$WORK/repo" rev-parse --verify --quiet refs/claude-wip/sess-D || echo "")
[ -n "$_snap" ] && [ "$(commit_count)" -eq "$_before" ] && report ok "猶予中のスナップショット ref が作られ HEAD は進まない" || report ng "スナップショットが作られない／HEAD が進んだ"
if [ -n "$_snap" ]; then
  git -C "$WORK/repo" cat-file -e "${_snap}:work.txt" 2>/dev/null && report ok "スナップショットに通常ファイルは含まれる" || report ng "スナップショットに通常ファイルが無い"
  git -C "$WORK/repo" cat-file -e "${_snap}:leak.py" 2>/dev/null && report ng "スナップショットに秘密入りファイルが含まれた" || report ok "スナップショット（GIT_INDEX_FILE 経路）でも秘密入りファイルを除外する"
fi
( cd "$WORK/repo" && CLAUDE_CODE_REMOTE=true CLAUDE_STOP_GIT_CHECK_BLOCKED=1 \
    bash "$STOP_HOOK" <<< '{"session_id":"sess-D","stop_hook_active":"false"}' >/dev/null 2>&1 )
[ "$(commit_count)" -eq $((_before + 1)) ] && report ok "秘密以外の作業は自動保全コミットされた（L-100 維持）" || report ng "自動保全コミットが作られなかった（L-100 後退）"
git -C "$WORK/repo" cat-file -e "HEAD:work.txt" 2>/dev/null && report ok "通常ファイルはコミットに含まれる" || report ng "通常ファイルがコミットに含まれない"
git -C "$WORK/repo" cat-file -e "HEAD:leak.py" 2>/dev/null && report ng "秘密入りファイルがコミットに含まれた" || report ok "秘密入りファイル（内容ルール）はコミットに含まれない"
git -C "$WORK/repo" cat-file -e "HEAD:.env" 2>/dev/null && report ng ".env がコミットに含まれた" || report ok ".env（ファイル名ルール）はコミットに含まれない"
[ -f "$WORK/repo/leak.py" ] && [ -f "$WORK/repo/.env" ] && report ok "除外した秘密ファイルは作業ツリーに残る（削除しない）" || report ng "除外した秘密ファイルが作業ツリーから消えた"
teardown_tmp_repo "$WORK"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
