#!/usr/bin/env bash
# publish-snapshot.sh — 公開専用リポジトリへ配布する「履歴なしスナップショット」を
# 作業ツリーの現在の内容から抽出する（Issue #379・migration_steps 1・6）。
#
# 背景: content/discussions/public-repo-split-20260801/ の lead 判定（案B Phase 0）により、
# 本リポジトリ（private・開発 SSOT）から配布物だけを履歴なしで公開専用リポジトリへ置く。
# git 履歴を持ち込まない理由は、コミット件名・本文が「隠したい情報の在り処」を平文で
# 開示してしまい編集で消せないため（r03 lead_verdict.md 参照）。
#
# 使い方（本リポジトリのルートで実行）:
#   bash scripts/publish-snapshot.sh <output-dir>              # 抽出して検証まで実行
#   bash scripts/publish-snapshot.sh <output-dir> --dry-run    # 何がコピーされ何が除外されるかを表示するだけ
#
# 出力先ディレクトリに .git がある場合（公開リポジトリを clone 済みのディレクトリを渡す運用）は
# .git だけ保持し、それ以外は作り直す（ベース側での削除が確実にスナップショットへ反映されるように）。
# git 履歴には一切触れない（add/commit/push は本スクリプトの責務外。docs/publish-workflow.md 参照）。
set -euo pipefail

log() { echo "[publish-snapshot] $*"; }
die() { echo "[publish-snapshot][ERROR] $*" >&2; exit 1; }

DRY_RUN=false
ALLOW_MISSING_SECRETS=false
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift;;
    --allow-missing-secrets) ALLOW_MISSING_SECRETS=true; shift;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0;;
    -*) die "不明なオプション: $1";;
    *)
      [ -z "$OUT_DIR" ] || die "出力先ディレクトリは 1 つだけ指定してください（既に指定済み: $OUT_DIR）"
      OUT_DIR="$1"; shift;;
  esac
done
[ -n "$OUT_DIR" ] || die "出力先ディレクトリを指定してください: bash scripts/publish-snapshot.sh <output-dir> [--dry-run] [--allow-missing-secrets]"

# --- 0. 実行位置の検証（本リポジトリのルートで実行することを強制）---
SRC="$(pwd)"
if ! git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "カレントディレクトリは git リポジトリではありません: $SRC"
fi
if [ -n "$(git -C "$SRC" rev-parse --show-cdup 2>/dev/null)" ]; then
  die "本リポジトリのルートディレクトリで実行してください: $SRC"
fi
[ -d "$SRC/.claude" ] || die "本リポジトリの構造（.claude/）が見つかりません。実行位置を確認してください"

# --- 1. 公開境界の定義（PUBLISH_PATHS / PUBLISH_DENYLIST）---
# 判断基準（迷ったパスに適用した実際の基準）:
#   「第三者がこのベースを使うのに必要か」→ 含める / 「著者の運用記録・下流固有情報か」→ 除外
#
# 含める: scripts/apply-to-repo.sh の SYNC_PATHS（下流配布用の 13 パス）+ 配布物として
# 第三者に必要な最上位ファイル。SYNC_PATHS 自体は下流「同期」用の定義であって公開境界ではないため
# （sync-feasibility の実測・r03 lead_verdict.md migration_steps 1）、ここで独立に定義する。
PUBLISH_PATHS=(
  # --- SYNC_PATHS 相当（apply-to-repo.sh と同一の 13 パス）---
  "docs/rules"                     # ルール本体（第三者がベースを使うのに必須）
  ".claude/rules"                  # docs/rules への symlink（ハーネスが参照）
  ".claude/hooks"                  # ハーネス本体
  ".claude/skills"                 # Agent Skills 一式
  ".claude/agents"                 # サブエージェント定義
  ".claude/output-styles"          # 応答スタイル定義
  ".claude/commands"                # スラッシュコマンド定義
  ".claude-plugin"                 # プラグインマニフェスト
  "tools"                          # 運用スクリプト・機械チェッカー一式
  "scripts"                        # bootstrap / apply-to-repo / 本スクリプト自身
  "modules.yaml"                   # モジュール一覧（enabled 切り替えの基盤）
  ".mcp.json"                      # MCP サーバ定義
  "requirements.txt"               # Python 依存関係
  # --- SYNC_PATHS 対象外だが公開に必須な最上位ファイル ---
  "README.md"                      # 第三者向けの唯一の入口ドキュメント
  "LICENSE"                        # 配布に法的に必須
  "NOTICE"                         # 同梱コード（skill-creator 等）の帰属表示
  "CLAUDE.md"                      # プロジェクト雛形の中核（第三者が最初に読む運用規約）
  ".gitignore"                     # 新規リポジトリでも同じ除外設定が要る
  "docs/project-mission.md"        # ミッション記入欄の雛形（プレースホルダごと配布）
  ".github"                        # PR テンプレート等（実在するファイルのみ）
  "docs/apply-to-existing-repo.md" # apply-to-repo.sh の使い方（第三者の主要な導入経路）
  "docs/base-update-notes.md"      # 下流向け移行ノート。apply-to-repo.sh:205-207 が実際に読んで
                                   # 「前回適用日以降の手動対応が必要な更新」を抜粋表示する機能ファイル。
                                   # 内部メモに見えるが下流にとっては必須（秘匿情報は含まない）
  # --- config/ は一律除外せず個別指定（状態ファイルと設定ファイルの性質が異なるため）---
  "config/claude_code_spec_sync.yaml" # spec-sync レーンの設定（キーワード辞書・ラベル・dedup）。
                                       # tools/check_claude_code_updates.py が起動時に open() で読み込み、
                                       # 無いとロード自体が失敗する（状態ではなく機能に必須のテンプレート）
  "config/publish_events.yaml"     # publish 通知イベントの設定。tools/slack_notify.py は未配置でも
                                    # 汎用既定（published のみ）にフォールバックするが、プロジェクト固有
                                    # イベントを追記するための拡張点テンプレートとして配る価値がある
  "config/broker_workflows.json.example" # verify_broker_migration.py のワークフロー別チェックリストの雛形
                                          # （プレースホルダのみでプロジェクト固有値を含まない・.example なのでテンプレート）
  ".claude/settings.json"          # 🔴 ハーネス本体（hooks 配線・outputStyle・permissions）。
                                   # apply-to-repo.sh は SYNC_PATHS ループではなく専用ステップでコピーするため
                                   # 13 パスに含まれない。これが欠けると .claude/hooks/*.sh がどのイベントにも
                                   # 紐付かず、ハーネスが恒久的に無効なまま配布される
)
# 除外（実在確認のうえ選定。著者の運用記録・議論の生ログ・下流プロジェクト固有情報）
PUBLISH_DENYLIST=(
  "content/discussions"                 # 敵対的議論の生ログ（コミット件名問題と同種の案内図になりうる・history-value 実測により参照は書き換え済み）
  "docs/reviews"                        # 過去の監査レビュー記録（著者の運用記録）
  "docs/proposals"                      # 採否未確定の内部提案（著者の検討記録）
  "docs/discussion_specs_base_only"     # 議論スキーマの内部テストデータ
  "content/analytics"                   # コスト・スプリントの実測データ（著者の運用記録）
  "content/research"                    # Deep Research の実行結果（著者の運用記録）
  "docs/routines.md"                    # R-1 ルーティン等、本リポジトリ固有の運用設定
  "docs/private-fork-adoption-proposal.md" # private フォーク運用の内部提案
  "docs/setup"                          # GitHub Project 設定等、著者環境固有の手順
  "docs/public-release-checklist.md"    # 本 private リポジトリ自身の公開可否判定記録（案B により当該判断は不要化・content/discussions/ 前提で読めない）
  "content/context"                     # project_state.md 等、実行時スナップショット（著者の運用記録）
  "content/pipeline-state"              # コストログ等の実行時テレメトリ（著者の運用記録）
  "config/claude_code_spec_state.json"  # spec-sync の実行状態（著者環境が既知化した Claude Code バージョン一覧）。
                                         # tools/check_claude_code_updates.py の load_state() はファイル不在時
                                         # {"known_ids": []} で初期化する設計のため、除外しても初回実行で自動生成される
  "config/broker_workflows.json"        # secrets broker 連携の実値（著者プロジェクト固有のワークフロー→環境変数キー）。
                                         # 配布するのは .json.example（雛形）のみ
  "infra"                               # secrets-broker 等、著者自身のインフラ構成
  ".claude/skills/base-harvest"         # 下流 → 開発リポジトリへの還流スキル。著者専用の運用スキルであり、
                                        # 仕様上 private 開発リポジトリのスラッグを恒久的に含む（分離後も正のまま維持するため）。
                                        # 公開すると「本当の開発 SSOT はどの private リポジトリか」を配布物自身が開示してしまう
  "tools/discussion_specs"              # 著者が過去に実行した議論のスペック（topic/brief に具体的な議題内容と
                                        # private スラッグを含む）。content/discussions を除外したのと同じ理由（著者の運用記録）で除外
)

# --- 秘匿語（下流 private リポジトリ名などの生値）---
#
# 🔴 秘匿語を本スクリプトに直書きしてはならない。
# 本スクリプトは PUBLISH_PATHS の "scripts" に含まれ、公開スナップショットへコピーされる。
# 直書きすると「秘匿語を検出するスクリプト」自身が秘匿語の公開源になる（実際に一度そうなった）。
# 自分自身を検証対象から除外して黙らせるのは、漏洩を隠すだけで解決にならない。
#
# 読み込み元は次の 2 つ。いずれも公開対象に含まれない:
#   1. 環境変数 PUBLISH_SECRET_TERMS（カンマ区切り）
#   2. リポジトリルートの .publish-secrets（1 行 1 語・# 始まりはコメント・.gitignore 済み）
# どちらも無い場合は fail-closed で停止する（--allow-missing-secrets で明示的に続行可）。
SECRET_TERMS=()
if [ -n "${PUBLISH_SECRET_TERMS:-}" ]; then
  IFS=',' read -r -a _env_terms <<< "$PUBLISH_SECRET_TERMS"
  for _t in "${_env_terms[@]}"; do
    _t="$(printf '%s' "$_t" | tr -d '[:space:]')"
    [ -n "$_t" ] && SECRET_TERMS+=("$_t")
  done
fi
if [ ${#SECRET_TERMS[@]} -eq 0 ] && [ -f "$SRC/.publish-secrets" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="$(printf '%s' "$_line" | tr -d '[:space:]')"
    case "$_line" in ''|'#'*) continue ;; esac
    SECRET_TERMS+=("$_line")
  done < "$SRC/.publish-secrets"
fi

log "ソース   : $SRC"
log "出力先   : $OUT_DIR"
$DRY_RUN && log "*** DRY-RUN モード（コピーは行いません）***"

# --- 2. dry-run: 何がコピー/除外されるかの一覧表示のみ ---
if $DRY_RUN; then
  echo ""
  log "── コピー対象（PUBLISH_PATHS）──"
  for p in "${PUBLISH_PATHS[@]}"; do
    if [ -e "$SRC/$p" ]; then
      log "  ~ would copy: $p"
    else
      log "  - skip（存在しない）: $p"
    fi
  done
  echo ""
  log "── 除外対象（PUBLISH_DENYLIST・参考表示）──"
  for p in "${PUBLISH_DENYLIST[@]}"; do
    if [ -e "$SRC/$p" ]; then
      log "  x excluded: $p"
    else
      log "  - （存在しない・除外リストのみ）: $p"
    fi
  done
  echo ""
  log "DRY-RUN 完了。--dry-run を外すと $OUT_DIR へ実際に抽出します。"
  exit 0
fi

# --- 3. 出力先の準備（.git があれば保持、それ以外は作り直す）---
if [ -d "$OUT_DIR" ]; then
  log "── 出力先を初期化（.git は保持）──"
  find "$OUT_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +
else
  mkdir -p "$OUT_DIR"
fi
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# --- 4. コピー実行 ---
log "── 抽出 ──"
for p in "${PUBLISH_PATHS[@]}"; do
  src="$SRC/$p"
  dst="$OUT_DIR/$p"
  if [ ! -e "$src" ]; then
    log "  - skip（存在しない）: $p"
    continue
  fi
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
  log "  + $p"
done

# --- 4.5. DENYLIST の適用（コピー後に削除する）---
# PUBLISH_PATHS はディレクトリを丸ごとコピーするため、その配下にある除外対象
# （例: .claude/skills 配下の特定スキル）は「コピーしない」では実現できない。
# コピーしてから消す。ここを飛ばすと §5.2 の検証で落ちるだけで、自動では除外されない。
denylist_removed=0
for p in "${PUBLISH_DENYLIST[@]}"; do
  if [ -e "$OUT_DIR/$p" ]; then
    rm -rf "${OUT_DIR:?}/$p"
    log "  - 除外（削除）: $p"
    denylist_removed=$((denylist_removed + 1))
  fi
done
[ "$denylist_removed" -eq 0 ] || log "  除外適用: ${denylist_removed} 件"

# --- 4.6. git 管理外ファイルの排除（最重要の安全網）---
# cp -a は「作業ツリーの現在の内容」をコピーするため、.gitignore 済みのファイルも拾ってしまう。
# 例: .claude/settings.local.json（秘密を書く場所・gitignore 済み）が作業ツリーに存在すれば
# そのまま公開物に入る。__pycache__ も同様。「追跡されているものだけを配る」を機械的に保証する。
log "── git 管理外ファイルの排除 ──"
untracked_removed=0
while IFS= read -r -d '' f; do
  rel="${f#"$OUT_DIR"/}"
  # 元リポジトリで追跡されているかを問い合わせる（追跡外なら公開物から削除）
  if ! git -C "$SRC" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    rm -f "$f"
    untracked_removed=$((untracked_removed + 1))
  fi
done < <(find "$OUT_DIR" -type f -not -path "$OUT_DIR/.git/*" -print0)
if [ "$untracked_removed" -gt 0 ]; then
  log "  - git 管理外のため削除: ${untracked_removed} 件（.gitignore 済みファイル・ビルド生成物等）"
else
  log "  ✓ git 管理外ファイルの混入: なし"
fi

# 空になったディレクトリを残さない（除外で中身が消えた親ディレクトリの掃除）
find "$OUT_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

# --- 5. 検証（1 つでも失敗したら非ゼロ終了）---
log "── 検証 ──"
VALIDATION_FAILED=false

# 5.1 秘匿語が 0 件であること
#
# 🔴 検証対象からファイルを除外しない。除外は漏洩を隠すだけで解決にならない。
# 秘匿語は外部（環境変数 / .publish-secrets）から読むため、本スクリプト自身が
# ヒットすることはない。ヒットしたら本当に公開物へ混入している。
if [ ${#SECRET_TERMS[@]} -eq 0 ]; then
  if $ALLOW_MISSING_SECRETS; then
    log "  ⚠ 秘匿語リストが未設定のためスキャンをスキップしました（--allow-missing-secrets 指定）"
  else
    log "  ✗ 秘匿語リストが未設定です。PUBLISH_SECRET_TERMS 環境変数か .publish-secrets を用意してください"
    log "    （意図的にスキャンなしで抽出する場合は --allow-missing-secrets を付ける）"
    VALIDATION_FAILED=true
  fi
else
  secret_hit=false
  for term in "${SECRET_TERMS[@]}"; do
    # -i: .publish-secrets.example が「大文字小文字は区別しない」と明記しているため合わせる。
    # -I（バイナリ除外）は付けない: __pycache__ 等のバイナリに秘匿語が入る経路を素通りさせないため。
    hits="$(grep -rli -- "$term" "$OUT_DIR" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      # 秘匿語そのものはログに出さない（ログが記録・共有される可能性があるため）
      log "  ✗ 秘匿語を含むファイルがあります:"
      printf '%s\n' "$hits" | sed 's/^/      /'
      secret_hit=true
      VALIDATION_FAILED=true
    fi
  done
  $secret_hit || log "  ✓ 秘匿語: 0 件（${#SECRET_TERMS[@]} 語をスキャン）"
fi

# 5.2 除外対象ディレクトリが混入していないこと
denylist_hit=false
for p in "${PUBLISH_DENYLIST[@]}"; do
  if [ -e "$OUT_DIR/$p" ]; then
    log "  ✗ 除外対象が混入しています: $p"
    denylist_hit=true
    VALIDATION_FAILED=true
  fi
done
$denylist_hit || log "  ✓ 除外対象ディレクトリの混入: なし"

# 5.3 機密ファイルパターンが含まれていないこと
dangerous_files="$(find "$OUT_DIR" -type f \( \
  -name ".env" -o -name ".env.*" -o -name "*.key" -o -name "*.pem" \
  -o -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \
  -o -iname "*credentials*" \
  \) 2>/dev/null || true)"
if [ -n "$dangerous_files" ]; then
  log "  ✗ 機密ファイルパターンを検出しました:"
  printf '%s\n' "$dangerous_files" | sed 's/^/      /'
  VALIDATION_FAILED=true
else
  log "  ✓ 機密ファイルパターン（.env/*.key/*.pem/*.db 等）: なし"
fi

# 5.4 公開物内の参照切れ（DENYLIST で除外したファイルを指す記述が残っていないか）
#
# 除外は「公開物からファイルを消す」だけで、そのファイルを指す記述までは消さない。
# private 側では実在するため気づけず、公開版でだけ壊れる。第三者が踏む実害なので必ず検査する。
# ハーネス本体（.claude/settings.json）の欠落もここで検出できる。
if [ -f "$OUT_DIR/tools/check_skill_references.py" ]; then
  if ref_out="$(cd "$OUT_DIR" && python3 tools/check_skill_references.py 2>&1)"; then
    log "  ✓ 参照切れ: なし（公開物のみで自己完結）"
  else
    log "  ✗ 公開物に参照切れがあります（除外したファイルを指す記述が残っています）:"
    printf '%s\n' "$ref_out" | sed 's/^/      /' | head -30
    log "    → 参照元の文言を修正するか、対象を PUBLISH_PATHS に含めてください"
    VALIDATION_FAILED=true
  fi
else
  log "  ⚠ tools/check_skill_references.py が公開物に無いため参照切れ検査をスキップしました"
fi

# 5.4 7 桁以上の hex 文字列（コミット SHA 断片の可能性）は警告のみ（正当な用途もあるためブロックしない）
hex_hits="$(grep -rnoE '\b[0-9a-fA-F]{7,40}\b' "$OUT_DIR" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${hex_hits:-0}" -gt 0 ]; then
  log "  ⚠ 7 桁以上の hex 文字列を ${hex_hits} 件検出（コミット SHA 断片の可能性・警告のみ・非ブロック）"
  log "    詳細: grep -rnoE '\\b[0-9a-fA-F]{7,40}\\b' $OUT_DIR"
else
  log "  ✓ 7 桁以上の hex 文字列: 0 件"
fi

if $VALIDATION_FAILED; then
  die "検証に失敗しました。上記の ✗ 項目を確認・修正してから再実行してください（push しないこと）"
fi

echo ""
log "✅ 抽出・検証 完了: $OUT_DIR"
log "次のステップ（git 操作は本スクリプトの責務外）は docs/publish-workflow.md を参照してください。"
