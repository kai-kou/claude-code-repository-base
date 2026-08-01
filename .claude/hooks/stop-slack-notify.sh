#!/bin/bash
# Stop hook: WIP自動コミット + Slackセッション終了通知
# セッション終了時に未コミット変更を自動保存し、Slackに通知する
set -euo pipefail

input=$(cat)

# 再帰防止（jq 失敗時は "false" にフォールバック）
stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // "false"' 2>/dev/null || echo "false")
if [[ "$stop_hook_active" == "true" ]]; then exit 0; fi

# git リポジトリでなければスキップ
if ! git rev-parse --git-dir >/dev/null 2>&1; then exit 0; fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── 日次コスト集計（#1213・#95・#106・#242）────────────────────────────
# 月次レポート（content/analytics/cost_monthly/YYYY-MM.json）は gitignore 対象で、
# main では追跡しない（#242）。高頻度更新テレメトリを feature ブランチに相乗りさせると
# churn 混入・未コミット誤検知でトークンを浪費するため、永続化経路を完全分離する:
#   - 本フックでは cost_log.jsonl への追記と月次 JSON のローカル更新（flush）のみ行う。
#   - 永続化は commit_cost_telemetry.py がテレメトリ専用データブランチ
#     telemetry/cost-data へ「1 日 1 回の plain git push」で行う（gh 非依存・後述ブロック）。
#
# 2 ステップ呼び出し:
#   1. --summary-only: 当セッションのコストを cost_log.jsonl に O_APPEND 追記
#   2. --flush --rotate: 追記済み cost_log.jsonl から月次 JSON を生成・古い行を削除
# ※ --summary-only を --flush に置換すると early return でセッションデータが欠落するため禁止。
_calc_script="${REPO_ROOT}/tools/calc_daily_cost.py"
if [[ -f "$_calc_script" ]] && command -v python3 &>/dev/null; then
  timeout 15s python3 "$_calc_script" --summary-only <<< "$input" >/dev/null 2>&1 || true
  timeout 15s python3 "$_calc_script" --flush --rotate >/dev/null 2>&1 || true
fi
unset _calc_script

# ── 月次コスト集計の永続化（telemetry/cost-data ブランチへ直 push・#242）──
# 作業中のチェックアウトに触れず、git plumbing でコミットを構築してデータブランチへ
# push する（PR・gh 不要）。--gate-daily で JST 当日 1 回に収束する
# （外部スケジューラ非依存。実データ差分が無ければ no-op で push しない）。
# 上の flush 直後に置き、最新の月次 JSON をローカルから読ませる。
_tele_script="${REPO_ROOT}/tools/commit_cost_telemetry.py"
if [[ "${CLAUDE_CODE_REMOTE:-}" = "true" ]] && [[ -f "$_tele_script" ]] && command -v python3 &>/dev/null; then
  # 120s: fetch/push リトライ込みの内部予算に余裕を持たせる。途中で SIGTERM されても
  # マーカーは成功後 stamp のため、同日中の次セッション Stop hook が再試行する（#243）
  timeout 120s python3 "$_tele_script" --gate-daily >/dev/null 2>&1 || true
fi
unset _tele_script

# ──────────────────────────────────────────
# 未コミット変更の自動保存（セッション終了時のファイルリセット防止）
# 問題: セッション終了後に新セッションが起動すると SessionStart フックが
#       git reset/checkout/clean を実行し未コミット変更が全て消える。
#       停止直前に自動コミット&プッシュすることで作業内容を保護する。
# 対象: クラウド環境（CLAUDE_CODE_REMOTE=true）かつ main/master 以外のブランチのみ
# ──────────────────────────────────────────
if [[ "${CLAUDE_CODE_REMOTE:-}" = "true" ]]; then
  _branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
  if [ -n "$_branch" ] && [ "$_branch" != "main" ] && [ "$_branch" != "master" ]; then
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)" ]; then
      _timestamp=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M' 2>/dev/null || date '+%Y-%m-%d %H:%M')
      # 月次コストテレメトリ（cost_monthly）は feature ブランチに混入させない（#106・#242）。
      # gitignore 化済みだが、gitignore 反映前の旧ブランチで追跡されている場合に備え
      # pathspec でも明示除外する（永続化は telemetry/cost-data ブランチが担う）。
      git -C "$REPO_ROOT" add -A -- . ':(exclude)content/analytics/cost_monthly/' 2>/dev/null || true
      # cost_monthly 以外に変更が無ければ何もコミットしない（空コミットを避ける）
      if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null && \
         git -C "$REPO_ROOT" commit -m "[wip] セッション終了前自動コミット（${_timestamp}）"; then
        # push 失敗時はリトライ（指数バックオフ: 2s, 4s, 8s）
        _pushed=false
        for _wait in 0 2 4 8; do
          [ "$_wait" -gt 0 ] && sleep "$_wait"
          if git -C "$REPO_ROOT" push -u origin "$_branch" 2>/dev/null; then
            _pushed=true
            break
          fi
        done
        if [ "$_pushed" = false ]; then
          echo "Warning: Stop-hook push failed after retries. Commit is local-only." >&2
        fi
        unset _pushed _wait
      fi
    fi
  fi
  unset _branch _timestamp
fi

# ──────────────────────────────────────────
# Slack 通知（session-stop）は廃止した（Issue #2597）
# ──────────────────────────────────────────
# セッション単位の開始/終了通知が通知氾濫の主因（約64通/日・全体の75〜85%）だったため、
# 「半日アウトカムサマリー」（tools/half_day_summary.py・07:00/19:00 発火）に集約した。
# 本フックに残る役割は「WIP 自動コミット」と「cost_log.jsonl へのコスト追記」のみ。
# （cost_log.jsonl は half_day_summary.py の稼働集計データソースになる）
exit 0
