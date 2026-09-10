#!/usr/bin/env bash
# bootstrap.sh — claude-code-base を新規プロジェクトに馴染ませる初期化スクリプト
#
# 役割:
#   1. プレースホルダ置換（__OWNER__/__REPO__, {{REPO_SLUG}}, {{PROJECT_NAME}} 等）
#   2. ベース固有の配布物（.claude-plugin/marketplace.json）を除去
#   3. タイムゾーンを modules.yaml へ反映（--tz）
#   4. .claude/rules/ の symlink を同期（check_rules_sync.sh --fix）
#   5. （任意）modules.yaml で enabled:false のモジュールを除去（--prune）
#
# 使い方:
#   bash scripts/bootstrap.sh --repo owner/repo --name "My Project" [--desc "説明"] [--tz Asia/Tokyo] [--prune]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_SLUG=""; PROJECT_NAME=""; PROJECT_DESC=""; PROJECT_TZ=""; PRUNE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_SLUG="$2"; shift 2;;
    --name) PROJECT_NAME="$2"; shift 2;;
    --desc) PROJECT_DESC="$2"; shift 2;;
    --tz)   PROJECT_TZ="$2"; shift 2;;
    --prune) PRUNE=true; shift;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [ -z "$REPO_SLUG" ]; then
  echo "ERROR: --repo owner/repo は必須です" >&2; exit 1
fi
OWNER="${REPO_SLUG%%/*}"
REPO="${REPO_SLUG##*/}"
PROJECT_NAME="${PROJECT_NAME:-$REPO}"
PROJECT_DESC="${PROJECT_DESC:-$PROJECT_NAME}"

# sed 置換値に含まれる特殊文字（区切りの # ・置換の & ・\）をエスケープする
_sed_esc() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
ESC_SLUG="$(_sed_esc "$REPO_SLUG")"
ESC_NAME="$(_sed_esc "$PROJECT_NAME")"
ESC_DESC="$(_sed_esc "$PROJECT_DESC")"
ESC_OWNER="$(_sed_esc "$OWNER")"
ESC_REPO="$(_sed_esc "$REPO")"

echo "[bootstrap] repo=$REPO_SLUG name=$PROJECT_NAME"

# 置換対象から外すファイル（正準パスで比較する）。
#   - bootstrap.sh 自身: 置換されると sed パターンが実プロジェクト名に化け、再実行が壊滅的になる
# プロジェクト固有の除外は本スクリプトに直書きせず、リポジトリ直下の `.bootstrap-no-replace`
# （1 行 1 パス・`#` 始まりはコメント・空行無視・ROOT からの相対パス）に列挙する。
# 本スクリプトは全下流へ配布される共有物なので、下流固有のパスを埋め込むと他プロジェクトへ
# 無関係な除外が配られる。プレースホルダを「説明のための文字列」として持つファイル
# （検査ツールの定数・仕様書の引用）は、そのプロジェクト側で登録すること
# （置換されると検査条件・仕様記述が実プロジェクト名に化け、再適用のたびに静かに壊れる）。
# ${BASH_SOURCE[0]} は起動時の表記（相対/絶対）をそのまま持つため、find の絶対パスと
# 直接比較すると相対起動（bash scripts/bootstrap.sh）で一致せず自己置換が起きる。
_canon() { ( cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd)" "$(basename "$1")" ); }
NO_REPLACE=(
  "$(_canon "${BASH_SOURCE[0]}")"
  "$(_canon "$ROOT/scripts/bootstrap.sh")"
)
NO_REPLACE_FILE="$ROOT/.bootstrap-no-replace"
if [ -f "$NO_REPLACE_FILE" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%%#*}"
    _line="$(printf '%s' "$_line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$_line" ] && continue
    if [ ! -e "$ROOT/$_line" ]; then
      echo "[bootstrap] WARN: .bootstrap-no-replace のエントリが存在しません: $_line" >&2
      continue
    fi
    NO_REPLACE+=("$(_canon "$ROOT/$_line")")
  done < "$NO_REPLACE_FILE"
fi
_is_no_replace() {
  local target; target="$(_canon "$1")"
  local skip
  for skip in "${NO_REPLACE[@]}"; do
    [ -n "$skip" ] && [ "$target" = "$skip" ] && return 0
  done
  return 1
}

# --- 1. プレースホルダ置換 ---
# 対象: docs/ .claude/ .claude-plugin/ tools/ scripts/ CLAUDE.md modules.yaml README.md .mcp.json（テキストのみ）
mapfile -d '' FILES < <(
  find "$ROOT/docs" "$ROOT/.claude" "$ROOT/.claude-plugin" "$ROOT/tools" "$ROOT/scripts" \
       "$ROOT/CLAUDE.md" "$ROOT/modules.yaml" "$ROOT/README.md" "$ROOT/.mcp.json" \
       -type f \( -name '*.md' -o -name '*.py' -o -name '*.sh' -o -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.txt' \) -print0 2>/dev/null
)
for f in "${FILES[@]}"; do
  # 置換すると自分自身の置換ロジックが壊れるファイルは除外する
  _is_no_replace "$f" && continue
  sed -i \
    -e "s#__OWNER__/__REPO__#${ESC_SLUG}#g" \
    -e "s#{{REPO_SLUG}}#${ESC_SLUG}#g" \
    -e "s#{{PROJECT_NAME}}#${ESC_NAME}#g" \
    -e "s#{{PROJECT_DESCRIPTION}}#${ESC_DESC}#g" \
    "$f" 2>/dev/null || true
done
# __OWNER__ / __REPO__ 単独（slug 置換後に残るもの）を個別に置換
for f in "${FILES[@]}"; do
  _is_no_replace "$f" && continue
  sed -i \
    -e "s#__OWNER__#${ESC_OWNER}#g" \
    -e "s#__REPO__#${ESC_REPO}#g" \
    "$f" 2>/dev/null || true
done
echo "[bootstrap] placeholders replaced in ${#FILES[@]} files"

# --- 1.5 ベース固有の配布物を除去 ---
# .claude-plugin/marketplace.json は「本ベースを配布するマーケットプレイス定義」であり、
# clone した新規プロジェクトが持つと、そのプロジェクトが claude-code-base を配布する
# マーケットプレイスを名乗ってしまう（プレースホルダ置換では直らない）。
if [ -f "$ROOT/.claude-plugin/marketplace.json" ]; then
  rm -f "$ROOT/.claude-plugin/marketplace.json"
  echo "[bootstrap] removed .claude-plugin/marketplace.json (base-only distribution manifest)"
fi

# --- 1.6 タイムゾーンを modules.yaml へ反映（--tz）---
# 従来 PROJECT_TZ は解析されるだけで書き込み先が無く、JST 統一ルールが効かなかった。
if [ -n "$PROJECT_TZ" ] && [ -f "$ROOT/modules.yaml" ]; then
  PROJECT_TZ="$PROJECT_TZ" python3 - "$ROOT/modules.yaml" <<'PYTZ'
import os, re, sys
path = sys.argv[1]
tz = os.environ["PROJECT_TZ"]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
in_project = False
done = False
for i, line in enumerate(lines):
    if re.match(r"^project:\s*$", line):
        in_project = True
        continue
    if in_project:
        if re.match(r"^\S", line):  # project ブロックを抜けた
            break
        m = re.match(r"^(\s*timezone:\s*)(\S.*|)$", line)
        if m:
            comment = ""
            rest = m.group(2)
            if "#" in rest:
                comment = "  " + rest[rest.index("#"):].strip()
            lines[i] = f'{m.group(1)}"{tz}"{comment}\n'
            done = True
            break
if done:
    open(path, "w", encoding="utf-8").write("".join(lines))
    print(f"[bootstrap] timezone={tz} を modules.yaml に反映しました")
else:
    print("[bootstrap] WARN: modules.yaml の project.timezone が見つからず --tz を反映できませんでした", file=sys.stderr)
PYTZ
fi

# --- 2. ルール symlink 同期 ---
if [ -x "$ROOT/tools/check_rules_sync.sh" ]; then
  bash "$ROOT/tools/check_rules_sync.sh" --fix || true
fi

# --- 3. 無効モジュールの除去（任意・--prune）---
if [ "$PRUNE" = true ]; then
  python3 "$ROOT/scripts/prune_modules.py" "$ROOT" || echo "[bootstrap] prune skipped (see message above)"
fi

echo "[bootstrap] done. 次のステップ:"
echo "  - docs/project-mission.md にミッション・KPI を記入"
echo "  - CLAUDE.md の応答スタイル / PR 自律化方針を確認"
echo "  - env は Claude.ai の環境設定に登録（GH_TOKEN は未設定でよい＝プロキシが認証を注入）"
echo "    ※ gh variable set 経由の登録はローカル実行専用（クラウドからは 403）"
