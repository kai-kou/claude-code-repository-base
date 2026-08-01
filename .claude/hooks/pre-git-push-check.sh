#!/bin/bash
set -euo pipefail
# PreToolUse hook: git push origin main のダイレクトpushブロック（ハードコンストレイント Lv3）
#
# Bash ツールで git push が実行される前に自動チェック。
# main ブランチへの直接 push を物理的にブロックする。
# 許可されるブランチ: content/*, claude/*, feat/*, fix/*, docs/*

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hook_block.sh
source "$HOOK_DIR/lib/hook_block.sh"

input=$(cat)

# Bash ツール以外はスキップ
tool_name=$(echo "$input" | jq -r '.tool_name // ""')
if [ "$tool_name" != "Bash" ]; then exit 0; fi

# コマンドを取得
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# git push コマンドでなければスキップ
if ! echo "$command" | grep -qE '(^|[;&|]\s*)git\s+push(\s|$)'; then exit 0; fi

# main/master への直接 push パターンを検出
#
# 判定ルール:
#   - " main" または " master" が行末にある（スタンドアロン引数）
#   - ":main" または ":master" が行末にある（refspec の dst）
#   - "git push" または "git push origin" のみで引数なし → 現在のブランチを確認
#
# 誤ブロックを防ぐため:
#   - "feat/main-test" のような / を含むブランチ名はマッチしない
#   - word-boundary ではなく行末 ($) でマッチさせる

# ブランチ名が明示されている場合のチェック
# (^|\s)(main|master)(\s*$) → スペース or 行頭 + main/master + 行末 or スペース
if echo "$command" | grep -qE '(^|\s)(main|master)\s*$' || \
   echo "$command" | grep -qE ':(main|master)\s*$'; then
  hook_block "[pre-git-push-check] ❌ main/master への直接 push をブロックしました。

ルール: main/master ブランチへの直接 push は禁止されています（PR 経由のみ）。

許可されているブランチへの push 例:
  git push -u origin content/V007-xxx
  git push -u origin claude/feature-abc
  git push -u origin feat/new-feature
  git push -u origin fix/bug-fix
  git push -u origin docs/update

PR 経由でマージしてください。"
fi

# ブランチ名未指定の場合: 現在のブランチが main/master なら push をブロック
# 例: "git push" / "git push origin" / "git push -u origin"
if echo "$command" | grep -qE '^git\s+push(\s+-[^ ]+)*(\s+[A-Za-z0-9._/-]+)?\s*$'; then
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    hook_block "[pre-git-push-check] ❌ main/master への直接 push をブロックしました。

ルール: main/master ブランチへの直接 push は禁止されています（PR 経由のみ）。

PR 経由でマージしてください。"
  fi
fi

exit 0
