#!/bin/bash
# Stop hook: 完了報告フォーマットチェック
#
# セッション終了時の最終アシスタントメッセージを検査し、
# 「PR マージ報告（プロセス）が主役で、ご依頼の再掲・アウトカムが欠落している」
# 典型バッドパターンのときだけ 1 回だけ是正リマインドを出す。
#
# 設計方針（ノイズ最小化）:
#   - no-op セッション・既に適正な報告（ご依頼/アウトカムを含む）は素通り（exit 0）
#   - 発火は「マージ」+「PR 参照」を含み、かつアウトカム系マーカーが無いときのみ
#   - stop_hook_active による再帰防止で 1 セッション 1 回に限定
#
# SSOT: docs/rules/completion-report-rules.md / CLAUDE.md「セッション完了報告」

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hook_block.sh
source "$HOOK_DIR/lib/hook_block.sh"

# 完了報告（マージ）信号: 「マージ完了」を示す表現に限定する。
# （単独の "squash" は "squash merge 予定" 等の未完了文脈を誤検知するため含めない。
#  英語の "squash merged" は [Mm]erged が拾う・日本語の "squash でマージしました" は マージしました が拾う）
MERGE_RE='マージしました|マージした|マージ済|[Mm]erged'
PR_REF_RE='PR ?#?[0-9]+|#[0-9]{2,}|プルリク|pull/[0-9]+'
# 適正な完了報告の構造マーカー（依頼の再掲 or アウトカム）
OUTCOME_RE='ご依頼|依頼内容|ご要望|アウトカム|できるように|できるようになり|頼まれ|お願いされ|当初の指示|最初の指示'

# テキストを分類: "nudge"（是正必要）/ "ok"（素通り）
classify_text() {
  local text="$1"
  # マージ報告でなければ対象外
  if ! printf '%s' "$text" | grep -qE "$MERGE_RE"; then
    echo "ok"; return
  fi
  # PR 参照が無ければ（一般的な「マージ」言及）対象外
  if ! printf '%s' "$text" | grep -qE "$PR_REF_RE"; then
    echo "ok"; return
  fi
  # アウトカム/依頼再掲の構造があれば適正 → 素通り
  if printf '%s' "$text" | grep -qE "$OUTCOME_RE"; then
    echo "ok"; return
  fi
  echo "nudge"
}

# ── セルフテスト ──
if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  assert() { # $1=text $2=expected
    local got; got=$(classify_text "$1")
    if [[ "$got" != "$2" ]]; then
      echo "FAIL: expected=$2 got=$got text=[$1]"; fail=1
    fi
  }
  # バッドパターン（是正対象）
  assert "PR #3052 を squash でマージしました！レビューの指摘も解消済みにゃ" "nudge"
  assert "ブランチを merged しました。pull/3052 完了にゃ" "nudge"
  # 適正（素通り）
  assert "**ご依頼**: 完了報告の改善。**アウトカム**: 遡らず把握できるようになったにゃ。補足: PR #3052 をマージ" "ok"
  assert "PR #3052 をマージし、レビュー指摘で何ができるようになったか整理したにゃ" "ok"
  # 非マージ報告（対象外）
  assert "候補を3件調べたにゃ。マージ作業は無いにゃ" "ok"
  assert "ファイルを編集したにゃ" "ok"
  # 未完了文脈の squash（誤検知しないこと）
  assert "PR #123 は squash merge 予定にゃ" "ok"
  if [[ $fail -eq 0 ]]; then echo "stop-completion-report-check: self-test PASS"; fi
  exit $fail
fi

input=$(cat 2>/dev/null || true)

# 再帰防止: 既にこのフック起因で再開済みなら何もしない
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // "false"' 2>/dev/null || echo "false")
if [[ "$stop_hook_active" == "true" ]]; then exit 0; fi

# transcript 取得
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
if [[ -z "$transcript" ]] || [[ ! -r "$transcript" ]]; then exit 0; fi

# 最終アシスタントメッセージ（テキストを含むもの）を抽出
last_text=$(tail -n 400 "$transcript" 2>/dev/null | jq -rs '
  [ .[]
    | select(.type=="assistant")
    | ((.message.content // []) | map(select(.type=="text") | .text) | join("\n"))
    | select(length > 0)
  ] | last // ""
' 2>/dev/null || echo "")

if [[ -z "$last_text" ]]; then exit 0; fi

if [[ "$(classify_text "$last_text")" == "nudge" ]]; then
  hook_block "📋 完了報告フォーマット確認: 直前の報告が「PR マージの詳細」中心になっているにゃ。ユーザーがチャットを遡らずに済むよう、**先頭に「ご依頼（最初に頼まれたことの再掲）→ アウトカム（何ができるようになったか）」** を置いて報告し直してにゃ。PR 番号・マージ・レビュー対応は補足に回すか省略する（SSOT: docs/rules/completion-report-rules.md）。"
fi

exit 0
