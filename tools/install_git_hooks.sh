#!/bin/bash
# .git/hooks/pre-commit に秘密検知フック（.claude/hooks/git-pre-commit.sh）を導入する（冪等・Issue #678）
#
# 呼び出し元: session-start.sh（クラウドの各セッション起動時）/ scripts/apply-to-repo.sh（下流適用時）/
#            手動 `bash tools/install_git_hooks.sh`（ローカルのクローン直後）
#
# 方針:
#   - 既存の pre-commit が本ベース由来（MARKER を含む）なら上書き更新、無ければ新規作成
#   - 本ベース由来でない pre-commit（husky / pre-commit フレームワーク等）は **壊さず** 警告だけ出す
#     （その場合も PreToolUse 側の `git commit` / `git push` 検査と PR 前検査は効く）
#   - core.hooksPath が設定済み（.husky/ 等・追跡ファイルの可能性）なら書き込まず警告だけ出す
#
# 終了コード: 常に 0（導入できなくても呼び出し元を止めない）
set -uo pipefail

MARKER="claude-code-base:secret-scan"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$REPO_ROOT" ]; then
  echo "[install-git-hooks] git リポジトリではないためスキップします" >&2
  exit 0
fi
if [ ! -f "$REPO_ROOT/.claude/hooks/git-pre-commit.sh" ]; then
  echo "[install-git-hooks] .claude/hooks/git-pre-commit.sh が無いためスキップします" >&2
  exit 0
fi

if [ -n "$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null || true)" ]; then
  echo "[install-git-hooks] ⚠ core.hooksPath が設定済みのため pre-commit を導入しません（そのフック側で \`bash .claude/hooks/git-pre-commit.sh\` を呼ぶよう追記してください）" >&2
  exit 0
fi

HOOKS_DIR="$(git -C "$REPO_ROOT" rev-parse --git-path hooks 2>/dev/null || echo "")"
case "$HOOKS_DIR" in
  /*) ;;
  "") echo "[install-git-hooks] hooks ディレクトリを解決できないためスキップします" >&2; exit 0 ;;
  *) HOOKS_DIR="$REPO_ROOT/$HOOKS_DIR" ;;
esac
TARGET="$HOOKS_DIR/pre-commit"

if [ -e "$TARGET" ] && ! grep -q "$MARKER" "$TARGET" 2>/dev/null; then
  echo "[install-git-hooks] ⚠ 既存の pre-commit（本ベース由来ではない）を保護し、上書きしません: $TARGET" >&2
  echo "[install-git-hooks]   → その pre-commit の先頭付近に \`bash \"\$(git rev-parse --show-toplevel)/.claude/hooks/git-pre-commit.sh\" || exit 1\` を追記してください" >&2
  exit 0
fi

mkdir -p "$HOOKS_DIR" 2>/dev/null || true
if cat > "$TARGET" <<EOF
#!/bin/sh
# ${MARKER} — tools/install_git_hooks.sh が導入（手で編集しない・再実行で上書きされる）
exec bash "\$(git rev-parse --show-toplevel)/.claude/hooks/git-pre-commit.sh" "\$@"
EOF
then
  chmod +x "$TARGET" 2>/dev/null || true
  chmod +x "$REPO_ROOT/.claude/hooks/git-pre-commit.sh" 2>/dev/null || true
  echo "[install-git-hooks] pre-commit（秘密検知）を導入しました: $TARGET" >&2
else
  echo "[install-git-hooks] ⚠ pre-commit を書き込めませんでした: $TARGET" >&2
fi
exit 0
