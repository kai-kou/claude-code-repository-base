#!/bin/bash
# Stop ルーター: セッション終了時の3つのフックを1つに統合
# トークン最適化: 3つの Stop フック → 1つに統合（CC-BUG-16 対策）
#
# 各チェックスクリプトを順に実行する。
# 1つが exit 2（ブロック）を返した場合でも、残りは実行する（終了処理は全て完了させる）。
#
# 【L-050 修正】複数サブスクリプトが個別に stdout/stderr 出力すると
# Claude Code が最初の1つしか解析しないリスクがある。
# → 各サブスクリプトの stderr（hook_block 経由のブロック理由）を一時ファイルで収集し、
#   最後に単一の stderr メッセージとして出力する（Issue #142: stdout JSON と exit 2 は排他のため
#   stdout JSON ではなく stderr に統一する）。

# stdin を保存して各サブスクリプトに渡す
INPUT=$(cat 2>/dev/null || true)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
FINAL_EXIT=0

# 一時ファイルでメッセージを収集（改行を保持するため変数ではなくファイルを使用）
MSG_FILE=$(mktemp /tmp/stop-router-msgs-XXXXXX)
trap 'rm -f "$MSG_FILE"' EXIT

# サブスクリプトを実行し、stderr のブロック理由を MSG_FILE に追記する関数
run_hook() {
  local script="$1"
  local err exit_code

  # stderr をキャプチャしつつ exit code を取得（set -e 未使用のため $? は確実にサブスクリプトの終了コード）
  err=$(printf '%s\n' "$INPUT" | "$HOOK_DIR/$script" 2>&1 >/dev/null)
  exit_code=$?

  if [ "$exit_code" -eq 2 ]; then
    FINAL_EXIT=2
    # 既存メッセージがあれば区切り線を挿入
    if [[ -s "$MSG_FILE" ]]; then
      printf '\n\n---\n\n' >> "$MSG_FILE"
    fi
    if [[ -n "$err" ]]; then
      printf -- '%s' "$err" >> "$MSG_FILE"
    else
      # stderr も空の場合: フォールバック文言を追記
      printf -- '%s がブロック理由を出力しませんでした（exit 2）' "$script" >> "$MSG_FILE"
    fi
  elif [ "$exit_code" -ne 0 ]; then
    # クラッシュ系（exit 1/127 等）も可視化してサイレントスキップを防ぐ（L-050 対策）
    FINAL_EXIT=2
    if [[ -s "$MSG_FILE" ]]; then
      printf '\n\n---\n\n' >> "$MSG_FILE"
    fi
    printf -- '%s が exit %s で失敗しました' "$script" "$exit_code" >> "$MSG_FILE"
  fi
}

# 1. Git 未コミットチェック
run_hook "stop-git-check.sh"

# 2. PR 存在チェック
run_hook "stop-pr-check.sh"

# 3. Slack 通知 + WIP 自動コミット
run_hook "stop-slack-notify.sh"

# 4. 完了報告フォーマットチェック（ご依頼再掲→アウトカム中心・completion-report-rules.md）
run_hook "stop-completion-report-check.sh"

# 収集したメッセージを単一の stderr 出力として出す（L-050: 複数メッセージ問題を修正）。
# 公式仕様: exit 2 時は stdout の JSON が無視されるため stderr に統一する（Issue #142）。
if [[ -s "$MSG_FILE" ]]; then
  cat "$MSG_FILE" >&2
fi

exit $FINAL_EXIT
