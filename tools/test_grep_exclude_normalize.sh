#!/bin/bash
# 再帰 grep への deny 除外オプション自動付与（pre-tool-use-router.sh +
# .claude/hooks/lib/grep_exclude_normalize.py・L-127）のデグレ検証。
#
# 検証対象:
#   - grep -r / -R / --recursive に --exclude 系が未指定なら updatedInput で除外を付与する
#   - --exclude 指定済み・git grep・非再帰 grep・rg は書き換えない（据え置き）
#   - **実行位置でない grep**（heredoc 本文・引用符内の文字列）を書き換えない（誤爆防止・CRITICAL 回帰）
#   - 除外パターンが settings.json の permissions.deny から生成されている（SSOT 追随）
#   - 書き換えブロックの追加で機密ファイルガード（.env / 鍵）が緩んでいない
#
# 使い方: bash tools/test_grep_exclude_normalize.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="$ROOT/.claude/hooks/pre-tool-use-router.sh"
NORMALIZER="$ROOT/.claude/hooks/lib/grep_exclude_normalize.py"
PASS=0
FAIL=0

# $1: ケース名 / $2: コマンド文字列 / $3: 期待（rewrite | passthrough | block）
run_case() {
  local name="$1" cmd="$2" expect="$3"
  local out rc actual
  out=$(printf '%s' "$cmd" | jq -Rs '{tool_name:"Bash", tool_input:{command:.}}' | "$ROUTER" 2>/dev/null)
  rc=$?

  # hook_block の契約は exit 2。それ以外の非ゼロは jq / パイプ側の異常なので block と区別する
  if [ "$rc" -eq 2 ]; then
    actual="block"
  elif [ "$rc" -ne 0 ]; then
    actual="error(rc=$rc)"
  elif printf '%s' "$out" | grep -q 'updatedInput'; then
    actual="rewrite"
  else
    actual="passthrough"
  fi

  if [ "$actual" = "$expect" ]; then
    echo "  [PASS] $name（$expect）"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $name: 期待 $expect / 実際 $actual — コマンド: $cmd"
    FAIL=$((FAIL + 1))
  fi
}

# $1: ケース名 / $2: コマンド文字列 / $3: 書き換え後に含まれてはならない文字列
assert_not_in_rewrite() {
  local name="$1" cmd="$2" forbidden="$3" out
  out=$(printf '%s' "$cmd" | python3 "$NORMALIZER" "--exclude='.env'" 2>/dev/null)
  if [ -z "$out" ] || ! printf '%s' "$out" | grep -qF "$forbidden"; then
    echo "  [PASS] $name"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $name: 書き換え結果に \"$forbidden\" が混入 — 結果: $out"
    FAIL=$((FAIL + 1))
  fi
}

echo "[test_grep_exclude_normalize] 開始"

echo "--- 書き換え対象（rewrite） ---"
run_case "再帰 grep（短縮結合オプション）" 'grep -rn "foo" .' rewrite
run_case "再帰 grep（-R）" 'grep -Rn "foo" src/' rewrite
run_case "再帰 grep（--recursive 長形式）" 'grep --recursive -n "foo" .' rewrite
run_case "-r が2番目以降のオプション" 'grep -n -r "foo" .' rewrite
run_case "パイプ後段に別 grep がある再帰 grep" 'grep -rn "foo" . | head -20' rewrite
run_case "git grep と再帰 grep の複合（後半のみ対象）" 'git grep -n foo && grep -rn bar .' rewrite

echo "--- 据え置き（passthrough） ---"
run_case "--exclude 指定済み" 'grep -rn --exclude=.env "foo" .' passthrough
run_case "--exclude-dir 指定済み" 'grep -rn --exclude-dir=.git "foo" .' passthrough
run_case "--include で対象が絞り込み済み" 'grep -rn --include=*.md "foo" .' passthrough
run_case "git grep 単体" 'git grep -n foo' passthrough
run_case "非再帰 grep" 'grep -n foo bar.txt' passthrough
run_case "rg（除外構文が異なるため未対応）" 'rg -n foo' passthrough
run_case "grep を含まないコマンド" 'ls -la docs/' passthrough
run_case "ヒアドキュメント本文の grep（誤爆防止）" 'cat > /tmp/x.sh <<EOF
grep -rn "TODO" .
EOF' passthrough
run_case "コマンド置換内の grep（誤爆防止）" 'echo "$(grep -rn foo .)"' passthrough

echo "--- 誤爆しないこと（実行位置でない grep） ---"
assert_not_in_rewrite "引用符内の文字列は書き換えない" 'git commit -m "run: grep -rn foo . later"' "--exclude"
assert_not_in_rewrite "printf の引数は書き換えない" "printf '%s' ' grep -rn'" "--exclude"

echo "--- deny 設定への追随（SSOT） ---"
DENY_SAMPLE=$(printf '%s' 'grep -rn foo .' | jq -Rs '{tool_name:"Bash", tool_input:{command:.}}' \
  | "$ROUTER" 2>/dev/null | jq -r '.hookSpecificOutput.updatedInput.command // ""')
for pat in ".env" "*.pem" "id_rsa"; do
  if printf '%s' "$DENY_SAMPLE" | grep -qF -- "--exclude='$pat'"; then
    echo "  [PASS] permissions.deny 由来の除外を生成: $pat"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] permissions.deny 由来の除外が欠落: $pat"
    FAIL=$((FAIL + 1))
  fi
done

echo "--- 機密ファイルガードのデグレ検証 ---"
run_case "機密ガード: .env の直接読み取り" 'cat .env' block
run_case "機密ガード: cwd 外の秘密鍵" 'cat ~/.ssh/id_rsa' block
# grep / rg を permissions.allow に載せた分、第2層ガードが cwd 外の実パスを見張る（パス様トークンのみ）
run_case "機密ガード: grep による cwd 外の秘密鍵読み取り" 'grep -n "" ~/.ssh/id_rsa' block
run_case "機密ガード: rg による cwd 外の認証情報読み取り" 'rg . ~/.aws/credentials' block
run_case "検索語が機密名でも誤ブロックしない" 'grep -rn "id_rsa" docs/' rewrite

echo "[test_grep_exclude_normalize] PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "[test_grep_exclude_normalize] ✅ OK"
