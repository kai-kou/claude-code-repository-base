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

# 機密ファイルへの Bash 経由アクセスをブロックする共通判定（#384 / 下流監査で全面刷新）
#
# 🔴 なぜ permissions.deny があるのに必要か（射程差）:
#    `permissions.deny` の `Read(**/...)` は **cwd アンカー**でプロジェクトディレクトリの外を守らない。
#    公式仕様上、Read 系 deny は Bash の認識済みファイルコマンド（cat/head/tail/sed 等）にも適用される
#    ため **cwd 内は deny が効く**（下流リポジトリでの対照実験で確認）。一方 `~/.ssh/id_rsa` /
#    `/tmp/foo.pem` / `~/.aws/credentials` のような **cwd 外の実パスは deny の射程外**で、
#    本関数群だけが第2層としてそこを塞ぐ。
#
# 設計方針と限界（過信しないこと）:
#   - **コマンド列挙型のため完全防御ではない**。`python3 -c "open(...)"` 等の任意コードは塞げない。
#     残余リスクはコンテナ隔離が引き受けており、本層は「うっかり漏洩」の抑止が目的
#   - クォート（"file" / 'file'）・リダイレクト（`cmd < file`）・コマンド置換（`$(cat x)` /
#     `` `cat x` ``）・サブシェル（`(cat x)`）経由も対象にする。ただし **パス途中でクォートを割る
#     難読化**（`cat ~/.ss''h/id_rsa`）は塞げない。`eval` 経由と同じ「意図的な回避」の類であり、
#     字面から実パスを復元するにはシェルの語彙解析が要るため本層の射程外とする
#   - **grep は対象に含めない**: `grep -rn .netrc docs/` のような文字列検索とファイル読み取りを
#     区別できず、正当な調査コマンドを止める実害が防御価値を上回るため
#   - **`.`（dot source）はコマンド位置に現れたときだけ対象にする**: `_sfa_cmds` に素で足すと
#     `find . -name credentials` / `git status . x` のカレントディレクトリ引数を誤ブロックするため、
#     行頭または `;` `&` `|` `(` 等の区切り直後の `.` に限定して抽出する（`source` と `.` は
#     POSIX 上の同義語であり、片方だけ守るのは片手落ちになる）
#   - コマンド名の直後の引数だけを見るため、"git commit -m '... .env ...'" は誤検知しない

# 判定対象のファイル名トークンを列挙する（コマンド直後の第1引数 + リダイレクト先）
_sfa_candidate_tokens() {
  _sfa_cmds='cat|less|head|tail|more|source|cp|mv|install|base64|xxd|od|strings|tar|rsync|curl|scp|sftp'
  printf '%s\n' "$COMMAND" \
    | grep -oE "(^|[[:space:];|&(\`{])(${_sfa_cmds})([[:space:]]+-[^[:space:];|&]+)*[[:space:]]+['\"]?[^[:space:];|&'\")]+" \
    | sed -E "s/.*[[:space:]]['\"]?//" || true
  printf '%s\n' "$COMMAND" \
    | grep -oE "<[[:space:]]*['\"]?[^[:space:];|&'\")]+" \
    | sed -E "s/^<[[:space:]]*['\"]?//" || true
  # dot source（`. file`）: コマンド位置（行頭 or 区切り直後）の `.` のみを対象にする。
  # `find . -name x` のように **引数位置** の `.` は直前が素の空白なので一致しない
  printf '%s\n' "$COMMAND" \
    | grep -oE "(^|[;|&(\`{][[:space:]]*)\.[[:space:]]+['\"]?[^[:space:];|&'\")-][^[:space:];|&'\")]*" \
    | sed -E "s/.*[[:space:]]['\"]?//" || true
}

# .env（本物のみ。.env.example 等のテンプレートは通す）
_sfa_env_access() {
  _sfa_hit=1
  while IFS= read -r _sfa_tok; do
    [ -n "$_sfa_tok" ] || continue
    _sfa_base="${_sfa_tok##*/}"
    case "$_sfa_base" in
      .env.example|.env.sample|.env.template|.env.dist|.env.example.*) continue ;;
      .env|.env.*) _sfa_hit=0; break ;;
    esac
  done <<EOF
$(_sfa_candidate_tokens)
EOF
  return $_sfa_hit
}

# 鍵・証明書・認証情報
#
# 判定は **ベース名スコープ**で行う（`config/credentials/README.md` のような **ディレクトリ名の一致**で
# 誤発火させない）。逆にベース名の中では語境界（先頭 or `-_.` 区切り）を見るため、
# `gcp-service-account.json` / `backup-id_rsa` のような **前置語つきの実ファイル名**も捕捉する。
_sensitive_file_access() {
  _sfa_hit=1
  while IFS= read -r _sfa_tok; do
    [ -n "$_sfa_tok" ] || continue
    # 判定は小文字化した文字列に対して行う（`foo.PEM` / `ID_RSA` のような大文字表記で
    # 拡張子・語境界の判定だけがすり抜けるのを防ぐ）
    _sfa_lower=$(printf '%s' "$_sfa_tok" | tr '[:upper:]' '[:lower:]')
    _sfa_base="${_sfa_lower##*/}"
    # 公開鍵は秘密ではない（`id_rsa.pub` を語境界判定で捕まえないため先に通す）
    case "$_sfa_base" in
      *.pub) continue ;;
    esac
    # 秘密ディレクトリ配下はファイル名を問わず対象（`~/.ssh/**` ・ `~/.aws/**` ・ `~/.gnupg/**`）。
    # **ホーム基準・絶対パス・先頭要素のときだけ** 一致させる（`docs/.ssh/README.md` のような
    # プロジェクト内の同名ディレクトリを巻き込まないため）。ディレクトリ自体を渡す
    # `cp -r ~/.ssh /tmp` も捕捉する。文書拡張子の除外より **先に** 評価する
    # （秘密ディレクトリ配下は拡張子を `.md` にしただけで素通りしてはならない）
    if printf '%s' "$_sfa_lower" \
      | grep -qE '^([~.]?/)?\.(ssh|aws|gnupg)(/|$)|^[~/][^[:space:]]*/\.(ssh|aws|gnupg)(/|$)'; then
      _sfa_hit=0; break
    fi
    case "$_sfa_base" in
      # 解説ドキュメントは対象外（"credentials" を扱う記事・手順書で通常運用が止まるのを防ぐ）
      *.md|*.markdown|*.rst|*.adoc|*.html|*.htm) continue ;;
      # 鍵・証明書は拡張子で判定
      *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore) _sfa_hit=0; break ;;
    esac
    # 認証情報はベース名の「語」で判定（語境界 = 先頭 or `-_.` 区切り）
    if printf '%s' "$_sfa_base" \
      | grep -qE '(^|[-_.])(git-credentials|netrc|credentials|service-accounts?|id_rsa|id_dsa|id_ecdsa|id_ed25519)([-_.][^/]*)?$'; then
      _sfa_hit=0; break
    fi
  done <<EOF
$(_sfa_candidate_tokens)
EOF
  return $_sfa_hit
}

# .env ファイルへのアクセスをブロック
if _sfa_env_access; then
  hook_block "BLOCK: .env ファイルへのアクセスは禁止されています"
fi

# 鍵・証明書・認証情報へのアクセスをブロック（#384）
if _sensitive_file_access; then
  hook_block "BLOCK: 機密ファイル（鍵・証明書・認証情報）への Bash 経由アクセスは禁止されています。
対象: *.pem / *.key / *.p12 / *.pfx / *.jks / *.keystore / ~/.ssh・~/.aws・~/.gnupg 配下 /
      ベース名が credentials・service-account・id_rsa 等の語に語境界で一致するファイル
      （.md 等の文書と .pub の公開鍵は対象外）
理由: permissions.deny は cwd アンカーのため cwd 外を守れず、本フックが第2層を担う。
デグレ検証: bash tools/test_sensitive_file_guard.sh"
fi

# 該当なし: 許可
exit 0
