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
#   - **grep / rg は「パス様トークン」だけを対象にする**: 検索パターンとファイル引数を字面で
#     区別できないため長らく対象外にしていたが、`Bash(grep:*)` を `permissions.allow` に載せると
#     静的評価で決着して classifier の審査にも到達しなくなるため、`grep -n "" ~/.ssh/id_rsa` の
#     ような **cwd 外の実パス読み取り** を第2層で見張る必要が生じた（Layer 1 セキュリティ指摘）。
#     そこで候補を **`/` か `~` を含むトークン** に限定する。第2層の目的が cwd 外の実パスである以上
#     これで十分で、`grep -rn "id_rsa" docs/` のような検索語はパス様でないため誤ブロックしない
#   - **`.`（dot source）はコマンド位置に現れたときだけ対象にする**: `_sfa_cmds` に素で足すと
#     `find . -name credentials` / `git status . x` のカレントディレクトリ引数を誤ブロックするため、
#     行頭または `;` `&` `|` `(` 等の区切り直後の `.` に限定して抽出する（`source` と `.` は
#     POSIX 上の同義語であり、片方だけ守るのは片手落ちになる）
#   - コマンド名の直後の引数だけを見るため、"git commit -m '... .env ...'" は誤検知しない
#     （ただし読み取り元がフラグ値や第2引数以降に来やすい cp/install/tar/rsync/scp は例外。下記参照）

# 判定対象のファイル名トークンを列挙する（コマンド直後の第1引数 + リダイレクト先 + 下記の多引数コマンド）
_sfa_candidate_tokens() {
  # curl はここに含めない: _sfa_multi_cmds（下記）の「呼び出しブロック全体から非フラグ位置引数を
  # 全て候補にする」抽出が、ここでの「フラグ後の第1トークンのみ」抽出を常に包含する強い上位互換
  # のため、二重登録は正規化前（@ 剥がし未適用）の重複トークンを生むだけで検知漏れの防止には
  # ならない（#417 Layer 1 レビューで指摘）。
  _sfa_cmds='cat|less|head|tail|more|source|cp|mv|install|base64|xxd|od|strings|tar|rsync|scp|sftp'
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
  # 読み取り元・アーカイブ対象が「値を取るフラグの値」や「第2引数以降」に来やすいコマンドは
  # 第1非フラグ引数だけでは取りこぼす（例: `install -m 600 ~/.ssh/id_rsa /tmp/x` の値は `600`、
  # `tar czf out.tgz ~/.ssh` / `cp -r src ~/.ssh` の機密パスは第2引数・#395）。
  # 対象をこの5コマンドに絞り、呼び出しブロック全体から非フラグ位置引数を全て候補にする。
  # 値を取るフラグの値そのもの（上記の `600`）や書き込み先も一緒に候補へ混じるが、
  # 実在の機密名パターンに一致しない限り誤検知は起きないため許容する。
  _sfa_multi_cmds='cp|install|tar|rsync|scp'
  printf '%s\n' "$COMMAND" \
    | grep -oE "(^|[[:space:];|&(\`{])(${_sfa_multi_cmds})[[:space:]]+[^;|&\`)]*" \
    | sed -E "s/^[[:space:];|&(\`{]?(${_sfa_multi_cmds})[[:space:]]+//" \
    | _sfa_tokenize_block || true
  # grep / rg 系（検索コマンド）は、パターンとファイル引数を字面で区別できない。上の設計方針の
  # とおり **`/` か `~` を含むパス様トークンだけ** を候補にして、検索語の誤ブロックを避けつつ
  # cwd 外の実パス読み取り（`grep -n "" ~/.ssh/id_rsa`）を捕捉する。
  _sfa_search_cmds='grep|egrep|fgrep|rg|ag|ack'
  printf '%s\n' "$COMMAND" \
    | grep -oE "(^|[[:space:];|&(\`{])(${_sfa_search_cmds})[[:space:]]+[^;|&\`)]*" \
    | sed -E "s/^[[:space:];|&(\`{]?(${_sfa_search_cmds})[[:space:]]+//" \
    | _sfa_tokenize_block \
    | grep -E '[/~]' || true
  # curl は上記5コマンドと違い「書き込み先（-o/--output/--output-dir）」を持つダウンロードが
  # 主用途のため別パイプラインにする（#419）。上記と同列に混ぜると書き込み先の値（ローカルへの
  # 保存先）が読み取り候補に混入し誤検知する（例: `curl -o /tmp/id_rsa https://example.com/file` は
  # ローカルの id_rsa を「読む」のではなくダウンロード結果で「上書きする」操作で、本ガードの目的
  # （機密ファイルの内容が Claude の文脈に漏洩することの防止）の対象外。書き込みによる上書き・
  # 破壊の防止は本ガードの守備範囲外＝`echo x > ~/.ssh/id_rsa` のような他のリダイレクト書き込みも
  # 元々対象外であり、curl -o だけを特別扱いしても防御水準は後退しない）。
  # 一方 `-T ~/.ssh/id_rsa`（アップロード＝読み取り）・`--data-binary @~/.aws/credentials`
  # （`@file` 構文でのローカル読み込み）は本物の読み取りなので候補に残す（#417）。
  # `-o` は `-sSfo <値>` のような結合短縮オプション（末尾が `o` で終わるクラスタ）でも次トークンを
  # 値として消費するため、フラグ側の正規表現は `-[A-Za-z]*o` で結合形も含めて拾う（`-O`〔大文字・
  # remote-name〕は値を取らない別フラグなので対象外のまま）。`--output-dir` は `--output` の
  # 前方一致で誤って途中一致しないよう、`[[:space:]]+`/`=` の直後境界チェックにより区別される。
  # 先頭の `@` はクォート同様に剥がし、ディレクトリベースの判定（`~/.aws/**` 等）が
  # `@` 付きトークンでも一致するようにする。クォート付き `"@path"` は先にクォートを剥がしてから
  # `@` を剥がす（1回の sed 置換に `['"@]` をまとめて詰めると `"@path"` の `@` が剥がれ残るため
  # 2段階にする、共通処理は `_sfa_tokenize_block` に集約）。
  # さらに URL（`scheme://...`）そのものは実在するローカルファイルパスではないため、
  # トークンの語尾がたまたま `credentials` 等に一致しても候補から除外する（例:
  # `curl https://api.example.com/v1/credentials` は API パスであり読み取り対象のローカル
  # ファイルではない・#419）。**ただし `file://` はローカルファイルを実際に読み出す curl 対応
  # スキームのため除外対象に含めない**（`curl file:///home/user/.ssh/id_rsa` を除外すると
  # 秘密鍵の内容が読み出され漏洩する。安全側に倒すため「除外してよいスキーム」を明示的な
  # ネットワーク系スキームの許可リストにし、未知のスキームは既定で候補に残す）。
  printf '%s\n' "$COMMAND" \
    | grep -oE "(^|[[:space:];|&(\`{])curl[[:space:]]+[^;|&\`)]*" \
    | sed -E "s/^[[:space:];|&(\`{]?curl[[:space:]]+//" \
    | sed -E 's/(^|[[:space:]])(-[A-Za-z]*o|--output|--output-dir)=[^[:space:]]+/ /g; s/(^|[[:space:]])(-[A-Za-z]*o|--output|--output-dir)[[:space:]]+[^[:space:]]+/ /g' \
    | _sfa_tokenize_block \
    | grep -viE '^(https?|ftps?|sftp|scp|smtps?|imaps?|pop3s?|ldaps?|dicts?|telnets?|tftp|gophers?|rtsp|rtmp|mqtt|wss?)://' || true
}

# _sfa_multi_cmds / curl 抽出の共通後段（トークン化 → フラグ除外 → クォート/@ 剥がし）
_sfa_tokenize_block() {
  tr -s '[:space:]' '\n' \
    | grep -vE '^-|^$' \
    | sed -E "s/^['\"]//;s/^@//;s/['\")]\$//"
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

# 再帰 grep への deny 除外オプション自動付与（auto モードの承認プロンプト削減・L-127）
#
# 🔴 なぜ必要か: 権限ルールは **deny → ask → allow の順**に評価され、最初に一致した段で決着する
#    （公式 permissions: "Rules are evaluated in order: deny, then ask, then allow"）。そのため
#    `grep -rn "x" .` のように **走査範囲に deny 対象（.env 等）が含まれる再帰検索**は、read-only でも・
#    allow に `Bash(grep:*)` を置いても deny/ask 側で決着して承認待ちになる。フックが allow を返しても
#    上書きできない（公式 permissions: "Hook decisions don't bypass permission rules"）。唯一の解が
#    **走査範囲から deny 対象を外すこと**なので、PreToolUse の `updatedInput`（公式仕様）でコマンド
#    自体に除外オプションを機械付与する。
#    ⚠️ ただし「除外を付ければ v2.1.259 の ask 条件（`grep -r` がディレクトリ経由で deny 対象へ到達）を
#    実際に回避できるか」は **未検証**（`docs/rules/lessons/permissions.md` の未検証セクション）。
#    効かないケースを観測したら同 lesson を更新すること。
#
# 安全性: 付与するのは「元々 deny で読めないファイル」の除外だけで、検索結果の意味は変わらない。
#         deny ルールも上の機密ファイルガード（_sensitive_file_access）も一切緩めない
#         （本ブロックはガード評価を通過した後にのみ到達する）。
# 除外パターンは **`settings.json` の `permissions.deny` を SSOT として動的生成** する。
# ここに静的リストを持つと deny 設定との 3 つ目の重複定義になり、deny にパターンを足したときの
# 更新漏れで「除外し損ねて再びプロンプトが出る」ドリフトが起きる（Layer 1 セルフレビュー指摘）。
# 変換規則: `Read(X)` の X について ① 末尾 `/**` はディレクトリ指定 → `--exclude-dir`
# ② 先頭 `**/` を除去 ③ 残りに `/` があればベース名のみ使う（grep の --exclude は glob が
# パス区切りを跨がないため）。
# 併せて、同ファイルの機密ファイルガード（_sensitive_file_access）だけが対象にしていて deny には
# 現れないパターン（*.pfx / *.jks / id_dsa 等）と、走査コスト上ほぼ常に不要な `.git` を補完する。
_grep_deny_excludes() {
  local settings="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}/.claude/settings.json"
  local pat base out=""

  if [ -f "$settings" ]; then
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      case "$pat" in
        */\*\*)
          base="${pat%/**}"; base="${base##*/}"
          [ -n "$base" ] && out="$out --exclude-dir='$base'"
          ;;
        *)
          base="${pat#\*\*/}"
          case "$base" in */*) base="${base##*/}" ;; esac
          [ -n "$base" ] && out="$out --exclude='$base'"
          ;;
      esac
    done <<EOF
$(jq -r '.permissions.deny[]? | capture("^Read\\((?<p>.+)\\)$").p // empty' "$settings" 2>/dev/null)
EOF
  fi

  # ガード側だけが持つパターンの補完（deny が薄いプロジェクトでも最低限を除外する）
  for base in '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore' 'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' '.netrc' '.git-credentials'; do
    case "$out" in *"--exclude='$base'"*) ;; *) out="$out --exclude='$base'" ;; esac
  done
  for base in '.git' '.ssh' '.aws' '.gnupg'; do
    case "$out" in *"--exclude-dir='$base'"*) ;; *) out="$out --exclude-dir='$base'" ;; esac
  done

  printf '%s' "${out# }"
}

# 判定と書き換えは `lib/grep_exclude_normalize.py` に委ねる（クォート状態を追跡して
# **実行位置の grep だけ**を書き換える）。素朴な sed 置換ではヒアドキュメント本文・引用符内の
# 文字列に現れた `grep -r` まで書き換わり、**書き出されるファイルの中身が化ける**
# （Layer 1 セルフレビューで CRITICAL 指摘・実測再現あり）。
# ここでの `grep -q grep` は Python 起動を避けるための前段フィルタにすぎない。
if printf '%s' "$COMMAND" | grep -q 'grep'; then
  _NEW_COMMAND=$(printf '%s' "$COMMAND" \
    | python3 "$HOOK_DIR/lib/grep_exclude_normalize.py" "$(_grep_deny_excludes)" 2>/dev/null) || _NEW_COMMAND=""
  if [ -n "$_NEW_COMMAND" ] && [ "$_NEW_COMMAND" != "$COMMAND" ]; then
    echo "[pre-tool-use-router] 再帰 grep に deny 対象の除外オプションを付与しました（L-127）" >&2
    jq -n --arg cmd "$_NEW_COMMAND" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": { "command": $cmd }
      }
    }'
    exit 0
  fi
fi

# 該当なし: 許可
exit 0
