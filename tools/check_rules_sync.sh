#!/usr/bin/env bash
# check_rules_sync.sh
# docs/rules/ と .claude/rules/ の同期状態を検証するスクリプト
#
# 使い方:
#   ./tools/check_rules_sync.sh          # 不足・リンク切れを報告して終了コードで示す
#   ./tools/check_rules_sync.sh --fix    # 不足シンボリックリンクを自動作成・リンク切れを削除する
#
# 終了コード:
#   0: 全ファイルが同期済み
#   1: 不足ファイルあり、またはリンク切れあり（--fix なしの場合）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_RULES="$REPO_ROOT/docs/rules"
CLAUDE_RULES="$REPO_ROOT/.claude/rules"
FIX_MODE=false

if [[ "${1:-}" == "--fix" ]]; then
  FIX_MODE=true
fi

missing=()
broken=()

# トークン最適化: .claude/rules/ に配置するのは「常時必要」なルールのみ。
# タスク依存のルールは docs/rules/ に実体のみ配置し、スキルが必要時に Read する。
# この ESSENTIAL_RULES リストに含まれないファイルは .claude/rules/ に symlink を作成しない。
ESSENTIAL_RULES=(
  "agent-team-summary.md"
  "completion-report-rules.md"
  "core-principles.md"
  "datetime-rules.md"
  "lessons-core.md"
  "pr-review-flow-summary.md"
  "session-compression-rules.md"
  "session-concurrency-rules.md"
  "session-safety-rules.md"
  "session-sprint-rules.md"
  "user-confirmation-minimization.md"
  "user-instruction-issue-rules.md"
  "user-notification-triage.md"
)

# Warm 降格済み（既定では Hot 層に常駐させない）:
#   - progress-reporting-rules.md: 制作系の長時間処理を行うときに該当パイプラインスキルが冒頭で Read する
#   - session-concurrency-rules.md: Scheduled Tasks（マルチセッション並行運用）を使うプロジェクトのみ symlink する
#     → 本リポジトリは R-1 ルーティン（docs/routines.md）の稼働開始に伴い Hot 化済み（E-B #20・PR #176）
#   - ai-reviewer-strategy.md: Warm 降格済み（#88）。現行 FAIR 構成の要点は圧縮版 + pr-review-flow-summary.md に記載
#   - autonomous-operation-policy.md: Warm 降格済み（#89）。user-confirmation-minimization.md / core-principles.md と大幅重複
#   - session-sprint-rules-detail.md: session-sprint-rules.md の詳細版（Warm 専用・#90）
#   - session-safety-rules-detail.md: session-safety-rules.md の詳細版（Warm 専用・#91）
# これらを Hot 層に戻したいプロジェクトは上の ESSENTIAL_RULES に追記して --fix を実行する。

# ESSENTIAL_RULES に含まれるファイルのみを同期対象にする（トークン最適化）
is_essential() {
  local filename_to_check="$1"
  for ess in "${ESSENTIAL_RULES[@]}"; do
    if [[ "$filename_to_check" == "$ess" ]]; then
      return 0
    fi
  done
  return 1
}

for docs_file in "$DOCS_RULES"/*.md; do
  filename="$(basename "$docs_file")"
  is_essential "$filename" || continue  # 常時必要なファイルのみチェック

  claude_target="$CLAUDE_RULES/$filename"

  if [[ ! -e "$claude_target" ]]; then
    missing+=("$filename")
    if $FIX_MODE; then
      ln -s "../../docs/rules/$filename" "$claude_target"
      echo "[FIXED] シンボリックリンクを作成: .claude/rules/$filename"
    else
      echo "[MISSING] .claude/rules/$filename が存在しません"
    fi
  fi
done

# 逆方向チェック: .claude/rules/ にシンボリックリンクがあるが docs/rules/ に実体がないケース
for claude_file in "$CLAUDE_RULES"/*.md; do
  filename="$(basename "$claude_file")"

  # シンボリックリンクのリンク先が存在するか確認
  if [[ -L "$claude_file" ]] && [[ ! -e "$claude_file" ]]; then
    echo "[BROKEN] .claude/rules/$filename はリンク切れのシンボリックリンクです"
    broken+=("$filename")
    if $FIX_MODE; then
      rm "$claude_file"
      echo "[FIXED] リンク切れを削除: .claude/rules/$filename"
    fi
  fi
done

if [[ ${#missing[@]} -eq 0 && ${#broken[@]} -eq 0 ]]; then
  echo "[OK] docs/rules/ と .claude/rules/ は同期されています"
  exit 0
else
  if $FIX_MODE; then
    echo "[OK] ${#missing[@]} 件のシンボリックリンクを作成、${#broken[@]} 件のリンク切れを削除しました"
    exit 0
  else
    total=$(( ${#missing[@]} + ${#broken[@]} ))
    echo "[NG] ${#missing[@]} 件のシンボリックリンクが不足、${#broken[@]} 件のリンク切れがあります（合計 ${total} 件）"
    echo "自動修正するには: ./tools/check_rules_sync.sh --fix"
    exit 1
  fi
fi
