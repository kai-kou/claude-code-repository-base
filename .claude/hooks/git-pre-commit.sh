#!/bin/bash
# git pre-commit フック本体: ステージ済み変更の秘密検知（Issue #678）
#
# tools/install_git_hooks.sh が .git/hooks/pre-commit（3 行のスタブ）からここへ exec する。
# Claude Code のフック（PreToolUse）とは別の **git 自身のフック** であり、
#   - Bash の `git add -A && git commit` 連結（PreToolUse 時点では index が空で検査できない）
#   - 自動保全コミット（pre-compact / post-compact / stop-slack-notify）
#   - 人間の手元のコミット
# を含む **全コミット経路** で発火する（`git commit --no-verify` だけが例外。その経路は
# pre-tool-use-router.sh の push 前検査と self_review_check.py の PR 前検査が受け止める）。
#
# 終了コード: 0 = 通過 / 1 = 検知（コミット中断）。スキャナ不在・実行エラー（exit 2）は
# 警告して通す（fail-open。スキャナの不具合で全コミットを止めると CP-6 の無人運用が崩れる）。
# 脱出ハッチ: CLAUDE_BASE_DISABLE_SECRET_SCAN=1（lib/secret_scan.sh 参照）。

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/secret_scan.sh
source "$HOOK_DIR/lib/secret_scan.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$REPO_ROOT" ] || exit 0

out=$(secret_scan_run "$REPO_ROOT" --staged 2>&1); rc=$?
case "$rc" in
  0) exit 0 ;;
  1)
    cat >&2 <<EOF
[secret-scan] ❌ コミットを中断しました。ステージ済みの変更に秘密（トークン・鍵・認証情報）の疑いがあります（#678）。

${out}

対処:
  秘密そのもの     → git rm --cached <path>（追跡解除）→ .gitignore へ追加 → 値をローテーション（既に push 済みなら必須）
  誤検知           → 該当行の末尾に \`secret-scan:ignore\`、またはテストフィクスチャ等は
                     config/secret_scan_allowlist.txt に glob を追記してから再コミット
  検査だけ再実行   → python3 tools/secret_scan.py --staged
EOF
    exit 1
    ;;
  *)
    echo "[secret-scan] ⚠ 秘密検知を実行できませんでした（exit=${rc}）。検査なしで通します: ${out}" >&2
    exit 0
    ;;
esac
