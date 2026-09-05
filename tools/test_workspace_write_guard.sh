#!/bin/bash
# tools/test_workspace_write_guard.sh — 作業領域外書き込みガード（.claude/hooks/lib/workspace_write_guard.py）の回帰テスト
#
# 判定対象は「無人ルーティンが承認プロンプトで停止する原因になるコマンド」（Issue #578）。
# 実際に停止した 2 例（下流 blog-dispatch ルーティン）を再現ケースとして先頭に置く。
#
# 使い方: bash tools/test_workspace_write_guard.sh
# 終了コード: 0 = 全ケース期待どおり / 1 = 期待と異なるケースあり
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/lib/workspace_write_guard.py"
TEST_CWD="/home/user/demo-repo"
TEST_HOME="/root"
TEST_SESSION="11111111-2222-3333-4444-555555555555"
PASS=0
FAIL=0

# run_case <期待: BLOCK|ALLOW> <説明> <コマンド>
run_case() {
  local expect="$1" desc="$2" cmd="$3"
  local payload output status actual
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"session_id":sys.argv[3],"tool_input":{"command":sys.argv[2]}}))' "$TEST_CWD" "$cmd" "$TEST_SESSION")
  output=$(printf '%s' "$payload" | HOME="$TEST_HOME" TMPDIR="" python3 "$GUARD" 2>&1)
  status=$?
  if [ "$status" -eq 1 ]; then actual="BLOCK"; else actual="ALLOW"; fi
  if [ "$actual" = "$expect" ]; then
    PASS=$((PASS + 1))
    printf '  ok   [%s] %s\n' "$expect" "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  NG   期待=%s 実際=%s : %s\n       cmd: %s\n' "$expect" "$actual" "$desc" "$cmd" >&2
    [ -n "$output" ] && printf '       out: %s\n' "$(printf '%s' "$output" | head -3 | tr '\n' ' ')" >&2
  fi
}

echo "[test] 停止した実例の再現"
run_case BLOCK "実例1: 変数経由で作業ツリー外に隔離ディレクトリを作る" \
  'WORK=/tmp/skill-doctor-demo; rm -rf $WORK; mkdir -p $WORK/.claude; cp -r /home/user/demo-repo/.claude/skills $WORK/.claude/skills'
run_case BLOCK "実例2: ホーム配下のツール結果ファイルを Bash で複製する" \
  "mkdir -p /tmp/claude-0/demo/$TEST_SESSION/scratchpad && cp /root/.claude/projects/demo/s/tool-results/r.txt /tmp/claude-0/demo/$TEST_SESSION/scratchpad/page1.json"

echo "[test] ブロックすべきケース"
run_case BLOCK "作業ツリー外への mkdir" 'mkdir -p /opt/demo-workspace'
run_case BLOCK "作業ツリー外へのリダイレクト書き込み" 'echo hi > /tmp/demo-out/a.txt'
run_case BLOCK "作業ツリー外への rm -rf" 'rm -rf /tmp/demo-out'
run_case BLOCK "作業ツリー外への cp（宛先が外）" 'cp ./report.md /tmp/demo-out/report.md'
run_case BLOCK "ホーム配下の Claude 領域の読み取り" 'cat /root/.claude/projects/demo/sess/tool-results/r.txt'
run_case BLOCK "チルダ表記のホーム配下 Claude 領域" 'ls ~/.claude/projects'

run_case BLOCK "GNU の -t で宛先を先頭指定する cp" 'cp -t /tmp/demo-out file1.txt file2.txt'
run_case BLOCK "--target-directory= 形式の宛先" 'cp --target-directory=/tmp/demo-out file1.txt'
run_case BLOCK "curl のダウンロード先が作業ツリー外" 'curl -o /tmp/demo-out/report.json https://example.com/r.json'
run_case BLOCK "wget の出力先が作業ツリー外" 'wget -O /tmp/demo-out/a.bin https://example.com/a.bin'
run_case BLOCK "sed -i による作業ツリー外の書き換え" 'sed -i "s/a/b/" /etc/demo.conf'
run_case BLOCK "dd の of= が作業ツリー外" 'dd if=/dev/zero of=/tmp/demo-out/blob bs=1M count=1'
run_case BLOCK "fd 付きリダイレクト（2>）" 'somecmd 2> /tmp/demo-out/err.log'
run_case BLOCK "noclobber 上書きリダイレクト（>|）" 'echo hi >| /tmp/demo-out/a.txt'
run_case BLOCK "cd で作業ツリー外へ移動してからの相対パス削除" 'cd /tmp/other-place && rm -rf temp_output'
run_case BLOCK "ラッパー（sudo）越しの削除" 'sudo rm -rf /tmp/demo-out/x'
run_case BLOCK "他セッションの scratchpad の削除" 'rm -rf /tmp/claude-0/demo/99999999-aaaa-bbbb-cccc-dddddddddddd/scratchpad'
run_case BLOCK "クォート内に & を含む URL があっても宛先を見失わない" \
  'curl "https://x.example/a?b=1&c=2" -o /tmp/demo-out/report.json'
run_case BLOCK "未終端 heredoc の後続行は解析対象に戻す（fail-closed）" \
  'cat <<EOF
intro
rm -rf /tmp/demo-out'

echo "[test] 通すべきケース"
run_case ALLOW "自セッションの scratchpad への書き込み" \
  "mkdir -p /tmp/claude-0/demo/$TEST_SESSION/scratchpad && echo hi > /tmp/claude-0/demo/$TEST_SESSION/scratchpad/a.txt"
run_case ALLOW "作業ディレクトリ内へのリダイレクト書き込み" 'echo hi > ./notes.md'
run_case ALLOW "作業ディレクトリ内の絶対パス書き込み" 'mkdir -p /home/user/demo-repo/build'
run_case ALLOW "相対パスの削除" 'rm -rf node_modules'
run_case ALLOW "外部パスからの読み取り（cp のソース）" 'cp /usr/share/doc/readme ./readme'
run_case ALLOW "外部パスの読み取り専用コマンド" 'grep -rn foo /usr/share/doc'
run_case ALLOW "プロジェクト内 .claude の読み取り" 'cat .claude/settings.json'
run_case ALLOW "スクリプト実行（内部の一時ディレクトリは射程外）" 'python3 tools/generate_project_context.py'
run_case ALLOW "解決できない変数を含むパス（判定不能は素通り）" 'mkdir -p "$EXTERNAL_BASE/x"'
run_case ALLOW "heredoc 本文に例示パスを含む文書生成（誤ブロック防止・導入直後に実発生）" \
  'cat > docs/note.md <<EOF
例: cat /root/.claude/projects/demo/tool-results/r.txt を Bash で読まない
例: rm -rf /tmp/demo-out は承認プロンプトになる
EOF'
run_case BLOCK "heredoc の外側の実コマンドは heredoc があっても判定される" \
  'rm -rf /tmp/demo-out && cat > ./note.md <<EOF
本文
EOF'

run_case ALLOW "クォート内の & を含む URL・宛先は作業ツリー内" \
  'curl "https://x.example/a?b=1&c=2" -o ./report.json'
run_case ALLOW "cd で作業ツリー内へ移動してからの相対パス削除" 'cd docs && rm -rf build'
run_case ALLOW "curl -O（出力先は cwd）" 'curl -O https://example.com/a.bin'
run_case ALLOW "/dev/null へのリダイレクト（誤ブロック防止・導入直後に実発生）" 'some-check 2>/dev/null | head -3'
run_case ALLOW "/dev/null を宛先にする dd" 'dd if=/dev/zero of=/dev/null bs=1M count=1'

run_case ALLOW "コマンド先頭の前置きトグル（#582・案内文どおりの外し方）" \
  'CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 rm -f /tmp/demo-out/marker'
run_case BLOCK "トグル名が後続セグメントに現れてもガードは外れない" \
  'rm -rf /tmp/demo-out; CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 echo done'
run_case BLOCK "トグル名が引数の文字列に現れてもガードは外れない" \
  'echo "CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1" && rm -rf /tmp/demo-out'
run_case BLOCK "トグルの適用範囲はそのセグメントに閉じる（後段は検査する）" \
  'CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 rm -f /tmp/demo-out/marker && rm -rf /tmp/demo-out/other'
run_case BLOCK "heredoc 本文にトグル名があってもガードは外れない" \
  'cat > docs/n.md <<EOF
CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 と書く
EOF
rm -rf /tmp/demo-out'

run_case BLOCK "シェルコメント内のトグル名では外れない" \
  'rm -rf /tmp/demo-out # CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1'
run_case BLOCK "複数行コマンドの後方行のトグルは前の行に及ばない" \
  'rm -rf /tmp/demo-out
echo x
CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 true'

echo "[test] トグルによる無効化"
toggle_out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"rm -rf /tmp/demo-out"}}))' "$TEST_CWD" \
  | HOME="$TEST_HOME" CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 python3 "$GUARD" 2>&1)
if [ $? -eq 0 ] && [ -z "$toggle_out" ]; then
  PASS=$((PASS + 1)); echo "  ok   [ALLOW] CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1 で素通りする"
else
  FAIL=$((FAIL + 1)); echo "  NG   トグルが効いていない" >&2
fi

echo "[test] ルーター統合（フックが exit 2 でブロックすること）"
router="$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/pre-tool-use-router.sh"
router_out=$(python3 -c 'import json; print(json.dumps({"tool_name":"Bash","cwd":"/home/user/demo-repo","tool_input":{"command":"mkdir -p /opt/demo-workspace"}}))' \
  | bash "$router" 2>&1)
router_status=$?
if [ "$router_status" -eq 2 ] && printf '%s' "$router_out" | grep -q "BLOCK:"; then
  PASS=$((PASS + 1)); echo "  ok   [BLOCK] ルーター経由で exit 2 になる"
else
  FAIL=$((FAIL + 1)); echo "  NG   ルーター統合: exit=$router_status out=$router_out" >&2
fi

echo
echo "[result] PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
