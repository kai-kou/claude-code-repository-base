#!/usr/bin/env bash
# tools/test_self_review_check.sh — self_review_check.py の Layer 0 強化チェック
# （bash 構文検査・Python 構文検査・対応テスト自動実行）の回帰テスト（Issue #627 対策 C）
#
# 検証する不変条件:
#   1. 構文エラーのある .sh・構文エラーのある .py・失敗する対応テスト（tools/test_<name>.sh）が
#      同一差分にあると exit=1 になり、3 種の Error 行がすべて出力される
#   2. 正常なファイルだけの差分では exit=0 になる
#   3. 対応テスト失敗は既定で Error（exit=1・ブロック）になる
#   4. SELF_REVIEW_SELFTEST=warn を付けると同じ対応テスト失敗が Warning に降格し exit=0 になる
#   5. ハイフン区切りのフック名（.claude/hooks/pre-x-y.sh）からアンダースコア名の対応テスト
#      （tools/test_pre_x_y.sh）が照合・実行される（対応テストは base 側に既存として置き、
#      「テストスクリプト自身の変更」経路で偶然通らない否定テストにする）
#   6. shellcheck（PATH 上のスタブ）/ ruff（導入済み環境のみ）の出力が Warning 化され exit=0 のまま
#   7. --self-test / 対応テストの実行時間予算の起点は GATE_STARTED（プロセス起動時）で、起点が予算超過分
#      だけ過去なら対応テストを 1 本も起動せず「未実行（予算超過）」を即座に返す（lint 段の経過を含めて数える・
#      起点を self_test_errors() 内に戻す退行を検出する否定テスト・#627 Layer 1 再レビュー指摘）
#
# 使い方: bash tools/test_self_review_check.sh
# 終了コード: 0 = 全 PASS / 1 = 1 件以上 FAIL

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF_REVIEW="$REPO_ROOT/tools/self_review_check.py"
[ -f "$SELF_REVIEW" ] || { echo "FATAL: チェッカーが見つかりません: $SELF_REVIEW"; exit 1; }

PASS=0
FAIL=0
report() { # report <結果 ok|ng> <説明>
  if [ "$1" = "ok" ]; then
    PASS=$((PASS + 1)); echo "  PASS: $2"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: $2"
  fi
}

# テスト用リポジトリ（作業ブランチ + push 先の bare リモート）を作る。origin はローカル
# bare のパスのまま使う（ネットワークに触れない）。changed_files() の主経路
# `git diff --name-only origin/<default>...HEAD` を実際に解決させるため、main を一度
# origin へ push して origin/main を作ってから各シナリオ用の feature branch を main から
# 切る（default_branch() は refs/remotes/origin/HEAD 未設定時 "main" 固定にフォールバック
# するため、origin/HEAD の設定は不要）。
setup_repo() {
  WORK=$(mktemp -d)
  git init --quiet --initial-branch=main "$WORK/remote.git" --bare 2>/dev/null \
    || git init --quiet --bare "$WORK/remote.git"
  git init --quiet --initial-branch=main "$WORK/repo" 2>/dev/null || {
    git init --quiet "$WORK/repo"
    git -C "$WORK/repo" checkout --quiet -B main
  }
  git -C "$WORK/repo" config user.email test@example.com
  git -C "$WORK/repo" config user.name test
  git -C "$WORK/repo" remote add origin "$WORK/remote.git"
  echo "base" > "$WORK/repo/base.txt"
  git -C "$WORK/repo" add -A
  git -C "$WORK/repo" commit --quiet -m base
  # ローカル bare へのローカル push でも環境によっては push negotiation の警告が
  # stderr に出ることがある（結果には影響しないが出力が汚れるため抑制する）。
  # origin/main が実際に解決できることは直後に明示検証し、フェイルオープンにしない。
  git -C "$WORK/repo" push --quiet -u origin main 2>/dev/null || true
  git -C "$WORK/repo" rev-parse --verify origin/main >/dev/null 2>&1 \
    || { echo "FATAL: setup_repo で origin/main を解決できませんでした"; exit 1; }
}

teardown_repo() { rm -rf "$WORK"; }

# write_failing_companion_fixture: tools/foo.py と常に失敗する tools/test_foo.sh を置く（ケース 1 / 3 共用）
write_failing_companion_fixture() {
  mkdir -p "$WORK/repo/tools"
  # ヒアドキュメントの本文と終端は関数内でもインデントしない（終端 EOS の一致に必要）
cat > "$WORK/repo/tools/foo.py" <<'EOS'
"""Dummy fixture module for self_review_check.py companion-test coverage."""


def add(a, b):
    return a + b
EOS
cat > "$WORK/repo/tools/test_foo.sh" <<'EOS'
#!/usr/bin/env bash
# tools/test_self_review_check.sh のフィクスチャ専用ダミーテスト（常に失敗する）。
echo "simulated failure for self_review_check companion-test coverage"
exit 1
EOS
}

# run_review <branch> [ENV_NAME=VALUE ...] → REVIEW_OUT / REVIEW_EXIT に結果を残す。
# SELF_REVIEW は現在リポジトリ（本テストの対象）の絶対パスなので、テスト対象は常に
# 「いま編集中の self_review_check.py」であり、フィクスチャリポジトリ側にはコピーしない。
run_review() {
  local branch="$1"; shift
  git -C "$WORK/repo" checkout --quiet "$branch"
  REVIEW_OUT=$(cd "$WORK/repo" && env "$@" python3 "$SELF_REVIEW" 2>&1)
  REVIEW_EXIT=$?
}

setup_repo

echo "[ケース 1] 構文エラー .sh + 構文エラー .py + 失敗する対応テストが同一差分 → exit=1・Error 3 種"
git -C "$WORK/repo" checkout --quiet -b feat/bad main
mkdir -p "$WORK/repo/tools"
cat > "$WORK/repo/bad.sh" <<'EOS'
#!/usr/bin/env bash
if [ true ]; then
  echo "oops"
EOS
cat > "$WORK/repo/bad.py" <<'EOS'
def broken(:
    pass
EOS
write_failing_companion_fixture
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit --quiet -m "add bad fixtures"

run_review feat/bad
[ "$REVIEW_EXIT" -eq 1 ] \
  && report ok "構文エラー + 対応テスト失敗が揃うと exit=1" \
  || report ng "exit=${REVIEW_EXIT}（期待 1）（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "構文エラー (bash -n): bad.sh" \
  && report ok "bash 構文エラーが Error 行として出力される" \
  || report ng "bash 構文エラーの Error 行が無い（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "構文エラー (python): bad.py:1" \
  && report ok "Python 構文エラーが Error 行として出力される（行番号込み）" \
  || report ng "Python 構文エラーの Error 行が無い（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "対応テスト失敗: tools/test_foo.sh（exit=1）" \
  && report ok "対応テスト失敗が Error 行として出力される" \
  || report ng "対応テスト失敗の Error 行が無い（出力: ${REVIEW_OUT}）"

echo "[ケース 2] 正常なファイルだけの差分 → exit=0"
git -C "$WORK/repo" checkout --quiet -b feat/good main
mkdir -p "$WORK/repo/tools"
cat > "$WORK/repo/tools/good.py" <<'EOS'
"""Dummy fixture module (valid syntax, no companion test)."""


def multiply(a, b):
    return a * b
EOS
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit --quiet -m "add good fixture"

run_review feat/good
[ "$REVIEW_EXIT" -eq 0 ] \
  && report ok "正常なファイルだけの差分は exit=0" \
  || report ng "exit=${REVIEW_EXIT}（期待 0）（出力: ${REVIEW_OUT}）"

echo "[ケース 3] 対応テスト失敗は既定で Error（exit=1・ブロック）"
git -C "$WORK/repo" checkout --quiet -b feat/companion-only main
mkdir -p "$WORK/repo/tools"
write_failing_companion_fixture
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit --quiet -m "add companion-only fixture"

run_review feat/companion-only
[ "$REVIEW_EXIT" -eq 1 ] \
  && report ok "既定（SELF_REVIEW_SELFTEST 未設定）では対応テスト失敗が exit=1" \
  || report ng "exit=${REVIEW_EXIT}（期待 1）（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "\[self-review\] Error" \
  && report ok "既定では Error セクションに出力される" \
  || report ng "Error セクションが無い（出力: ${REVIEW_OUT}）"

echo "[ケース 4] SELF_REVIEW_SELFTEST=warn で Warning に降格 → exit=0"
run_review feat/companion-only SELF_REVIEW_SELFTEST=warn
[ "$REVIEW_EXIT" -eq 0 ] \
  && report ok "SELF_REVIEW_SELFTEST=warn では対応テスト失敗があっても exit=0" \
  || report ng "exit=${REVIEW_EXIT}（期待 0）（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "対応テスト失敗: tools/test_foo.sh（exit=1）" \
  && report ok "対応テスト失敗の内容自体は Warning として出力される" \
  || report ng "対応テスト失敗の Warning 行が無い（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "\[self-review\] Error" \
  && report ng "SELF_REVIEW_SELFTEST=warn なのに Error セクションが残っている（出力: ${REVIEW_OUT}）" \
  || report ok "SELF_REVIEW_SELFTEST=warn では Error セクションが出ない"

echo "[ケース 5] ハイフン区切りのフック名（.claude/hooks/pre-x-y.sh）→ アンダースコア名の対応テスト（tools/test_pre_x_y.sh）が実行される"
# 対応テストは base（main・origin）側に既存として置き、差分にはフックだけが現れるようにする
# （「テストスクリプト自身の変更」経路で偶然通らないための否定テスト）
git -C "$WORK/repo" checkout --quiet main
mkdir -p "$WORK/repo/tools"
cat > "$WORK/repo/tools/test_pre_x_y.sh" <<'EOS'
#!/usr/bin/env bash
# ハイフン → アンダースコア照合のフィクスチャ専用ダミーテスト（常に失敗する）。
echo "simulated failure for hyphen-to-underscore companion lookup"
exit 1
EOS
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit --quiet -m "add companion test on base"
git -C "$WORK/repo" push --quiet origin main 2>/dev/null || true
git -C "$WORK/repo" checkout --quiet -b feat/hyphen-hook main
mkdir -p "$WORK/repo/.claude/hooks"
cat > "$WORK/repo/.claude/hooks/pre-x-y.sh" <<'EOS'
#!/usr/bin/env bash
echo "dummy hook fixture"
EOS
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit --quiet -m "add hyphenated hook fixture"
git -C "$WORK/repo" diff --name-only origin/main...HEAD | grep -q '^tools/test_pre_x_y.sh$' \
  && report ng "フィクスチャ不備: 対応テストが差分に含まれている（否定テストとして無効）" \
  || report ok "差分にはフックだけが現れる（対応テストは base 側に既存）"

run_review feat/hyphen-hook
printf '%s' "$REVIEW_OUT" | grep -q "対応テスト失敗: tools/test_pre_x_y.sh（exit=1）" \
  && report ok "ハイフン区切りのフック名からアンダースコア名の対応テストが実行される" \
  || report ng "対応テスト（tools/test_pre_x_y.sh）が実行されていない（出力: ${REVIEW_OUT}）"

echo "[ケース 6] shellcheck / ruff の Warning 経路 → スタブ（shellcheck）と実ツール（ruff・導入済み環境のみ）の出力が Warning 化される"
git -C "$WORK/repo" checkout --quiet -b feat/lint main
cat > "$WORK/repo/lint_target.sh" <<'EOS'
#!/usr/bin/env bash
unused_var="x"
echo "ok"
EOS
cat > "$WORK/repo/lint_target.py" <<'EOS'
"""Fixture with an undefined name (ruff F821)."""


def run():
    return undefined_name
EOS
git -C "$WORK/repo" add -A
git -C "$WORK/repo" commit --quiet -m "add lint fixtures"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/shellcheck" <<'EOS'
#!/usr/bin/env bash
# shellcheck のスタブ（gcc 形式の出力を 1 行返す）。self_review_check.py のパース経路の検証用
echo "lint_target.sh:2:1: warning: unused_var appears unused. [SC2034]"
EOS
chmod +x "$WORK/bin/shellcheck"
run_review feat/lint PATH="$WORK/bin:$PATH"
[ "$REVIEW_EXIT" -eq 0 ] \
  && report ok "lint 系は Warning のみで exit=0" \
  || report ng "exit=${REVIEW_EXIT}（期待 0）（出力: ${REVIEW_OUT}）"
printf '%s' "$REVIEW_OUT" | grep -q "shellcheck: lint_target.sh:2:1: warning" \
  && report ok "shellcheck の出力が Warning 化される（スタブ経由）" \
  || report ng "shellcheck Warning が無い（出力: ${REVIEW_OUT}）"
if command -v ruff >/dev/null 2>&1; then
  printf '%s' "$REVIEW_OUT" | grep -q "ruff: .*lint_target.py.*F821" \
    && report ok "ruff の未定義名（F821）が Warning 化される" \
    || report ng "ruff Warning が無い（出力: ${REVIEW_OUT}）"
else
  report ok "ruff 未導入のためスキップ（導入済み環境で検証される）"
fi

teardown_repo

echo "[ケース 7] 予算の起点は GATE_STARTED（プロセス起動時）を共有する（起点が過去なら対応テストを起動せず未実行 Error）"
_gate_out=$(cd "$REPO_ROOT" && python3 - <<'PY'
import sys, time
sys.path.insert(0, "tools")
import self_review_check as m
# 起点を予算超過分だけ過去へずらす → 対応テスト（tools/test_self_review_check.sh）は起動されず
# 「未実行（予算超過）」になる。起点を self_test_errors() 内で取り直す実装に退行すると、ここで
# 対応テストが実際に走ってしまい（本スクリプトの再帰実行・数秒）、ERRS の件数が 0 になる
m.GATE_STARTED = time.monotonic() - (m.SELF_TEST_BUDGET_SECONDS + 5)
t0 = time.monotonic()
errs = m.self_test_errors(["tools/self_review_check.py"])
elapsed = time.monotonic() - t0
print("ERRS", len(errs), all(("未実行" in e and "予算" in e) for e in errs), f"{elapsed:.1f}")
# 起点を現在に戻すと予算内なので、軽いコマンドは実際に実行されて成功する（判定が起点を読んでいる裏付け）
m.GATE_STARTED = time.monotonic()
errs2 = []
m._run_within_budget(["true"], "対応テスト", "true", m.GATE_STARTED, errs2, "true")
print("FRESH", len(errs2))
PY
)
printf '%s\n' "$_gate_out" | grep -qE '^ERRS [1-9][0-9]* True ' \
  && report ok "起点が予算超過分だけ過去なら対応テストを起動せず「未実行（予算超過）」を返す" \
  || report ng "予算超過の起点で未実行 Error にならない（出力: ${_gate_out}）"
printf '%s\n' "$_gate_out" | grep -qE '^ERRS [0-9]+ True [01]\.[0-9]$' \
  && report ok "予算超過時は対応テストを実際には走らせない（2 秒未満で判定）" \
  || report ng "予算超過時に対応テストが実行された疑い（出力: ${_gate_out}）"
printf '%s\n' "$_gate_out" | grep -q '^FRESH 0$' \
  && report ok "起点が現在なら予算内としてコマンドを実行する（起点を読んでいる裏付け）" \
  || report ng "起点を現在に戻しても実行されない（出力: ${_gate_out}）"


echo
echo "結果: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
