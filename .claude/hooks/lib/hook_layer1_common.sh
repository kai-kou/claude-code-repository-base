#!/bin/bash
# hook_layer1_common.sh — post-review-write-mark.sh / pre-merge-layer1-check.sh の共通ヘルパー
# （Issue #512 Layer 1 セルフレビュー指摘: 同一ロジックが2ファイルへコピペされていたため抽出）
#
# post-merge-publish-check.sh も同種の repo_slug_from_url() を独自に持つが、Issue #512 の
# スコープ外（既存ファイル）のため本ライブラリへは統合していない。3ファイル揃えるなら別 Issue で。

# origin リモート URL から owner/repo を切り出す
hook_repo_slug_from_url() {
  printf '%s' "$1" | sed -E 's#/+$##; s#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#'
}

# tool_input の owner/repo が期待値と一致するか判定する。
# 期待値（expected_owner/expected_repo）が空のときは検証をスキップする（= 一致扱い）。
# これは origin リモートが解決できない異常系のフェイルオープン。post-merge-publish-check.sh の
# 既存パターンをそのまま踏襲しており、Layer 1 レビューでも「実運用では git dir 内で常に
# origin が解決できるため実害は無い（このコンテナは常に origin 付きで clone される）」と
# 確認済み（過検証を避けるため意図的に変えていない）。
# 戻り値: 0=一致（またはチェック対象外） / 1=不一致
hook_owner_repo_match() {
  local owner="$1" repo="$2" expected_owner="$3" expected_repo="$4"
  if [[ -n "$owner" && -n "$expected_owner" && "$owner" != "$expected_owner" ]] \
     || [[ -n "$repo" && -n "$expected_repo" && "$repo" != "$expected_repo" ]]; then
    return 1
  fi
  return 0
}

# stdin JSON から session_id を抽出しサニタイズする（ファイル名に使うため英数字とハイフンのみ・64文字まで）
hook_extract_session_id() {
  printf '%s' "$1" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | cut -c1-64
}
