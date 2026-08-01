#!/bin/bash
set -euo pipefail
# PreToolUse ルーター: Bash ツール実行前のチェックを1つのフックに統合
# トークン最適化: 複数の PreToolUse(Bash) フック → 1つに統合
#
# stdin から JSON を受け取り、コマンド内容に応じて適切なチェックスクリプトに委譲する。
# 各チェックスクリプトは引き続き独立したファイルとして存在する（保守性維持）。
#
# プロジェクト固有のチェック（画像生成モデル制約・SNS 投稿クールダウン等）を
# 追加したい場合は、本ルーターに分岐を足してチェックスクリプトを呼び出す。

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/hook_block.sh
source "$HOOK_DIR/lib/hook_block.sh"

# ツール名を抽出（printf を使い、バックスラッシュを含む入力でも echo のエスケープ解釈に依存しない）
TOOL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.tool_name // ""')

# MCP 経由の PR 作成（mcp__github__create_pull_request）も Bash の gh pr create と同じ
# 事前ゲート（未コミット検出 + セルフレビュー機械チェック + Layer 1 リマインダー）に通す。
# クラウド環境では gh pr create が proxy 403 で失敗し MCP 経由が PR 作成の主経路になるため、
# matcher 外だと Layer 0 ゲートを完全素通りしてしまう（再発防止・FAIR Layer 1 スキップの根本原因）。
if [ "$TOOL_NAME" = "mcp__github__create_pull_request" ]; then
  printf '%s\n' "$INPUT" | "$HOOK_DIR/pre-pr-create-check.sh"
  exit $?
fi

# コマンド文字列を抽出（JSON の tool_input.command フィールド）
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# git push チェック（main/master 直接 push のブロック）
# 【注意】"git" と "push" が隣接する 'git\s+push' だけだと `git -C <path> push ...` を
# 取りこぼす（critical 1 の再発防止・pre-git-push-check.sh 側の再設計と対）。
# "git" と "push" が単語としてどちらもコマンド中に現れれば委譲し、精密な判定は
# pre-git-push-check.sh 側のセグメント解析に任せる（push でないなら向こうが allow で返す）。
if echo "$COMMAND" | grep -qE '\bgit\b' && echo "$COMMAND" | grep -qE '\bpush\b'; then
  echo "$INPUT" | "$HOOK_DIR/pre-git-push-check.sh"
  exit $?
fi

# PR 作成チェック（未コミット・未push 検出 + セルフレビュー機械チェック）
if echo "$COMMAND" | grep -qE '(gh\s+pr\s+create|poll_pr_reviews)'; then
  echo "$INPUT" | "$HOOK_DIR/pre-pr-create-check.sh"
  exit $?
fi

# .env ファイルへのアクセスをブロック（Bash コマンド経由: cat/source/.env 等）
# 注意: "git commit -m '... .env ...'" 等のコミットメッセージへの誤検知を防ぐため、
# ファイルアクセスコマンド直後の引数として .env が現れるパターンのみブロックする
if echo "$COMMAND" | grep -qE '(^|[[:space:];|&])(cat|less|head|tail|more|source|grep|\.)([[:space:]]+-[^[:space:];|&]+)*[[:space:]]+([^[:space:];|&]*/)?\.env([^[:space:];|&]*)?([[:space:];|&]|$)'; then
  hook_block "BLOCK: .env ファイルへのアクセスは禁止されています"
fi

# 該当なし: 許可
exit 0
