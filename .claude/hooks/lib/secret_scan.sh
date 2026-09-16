#!/bin/bash
# 秘密検知ゲート（tools/secret_scan.py）のフック向け共通ヘルパー（Issue #678）
#
# 使い方: source "$(dirname "$0")/lib/secret_scan.sh" してから
#   secret_scan_path <repo_root>                 → スキャナの絶対パスを stdout に返す（無ければ空・exit 1）。
#                                                  探索順: <repo_root>/tools → $SECRET_SCAN_HOME/tools（別リポジトリを
#                                                  検査するときの本体置き場）→ $CLAUDE_PLUGIN_ROOT/tools（プラグイン配布）
#   secret_scan_run  <repo_root> <args...>       → <repo_root> を cwd にしてスキャナを実行し終了コードをそのまま返す
#                                                  （0/1/2）。スキャナ不在・無効化（CLAUDE_BASE_DISABLE_SECRET_SCAN=1）は 0。
#                                                  🔴 呼び出し側が `set -e` のときは `out=$(secret_scan_run …) || rc=$?` の形で
#                                                  受けること（`out=$(…); rc=$?` は errexit で代入時に script ごと落ち、
#                                                  hook_block に到達せず exit 1（非ブロック）で終わる・#680 Layer 1 指摘）
#   secret_scan_join_lines <command>             → バックスラッシュ + 改行の継続行を 1 行に連結して stdout に返す
#                                                  （grep の行単位判定を継続行で回避されないようにする）
#   secret_scan_target_dir <command> <verb>      → `git … <verb>`（verb = commit | push）が実行されるディレクトリを
#                                                  コマンド文字列から静的に解決して stdout に返す。同一セグメントの
#                                                  `git -C <dir>` を最優先、無ければ **その直前までの最後の `cd <dir>`**
#                                                  （`cd A && cd B && git commit` は B。verb より後ろの `cd` は無視）。
#                                                  変数展開・チルダ・不在パスは解決不能として空文字を返す
#                                                  （呼び出し側は cwd のリポジトリへフォールバック）
#   secret_scan_commit_bypass <command>          → `git commit` の pre-commit 無効化（`--no-verify` / `-n` を含む短縮フラグ束 /
#                                                  `-c core.hooksPath=…`）を **shlex でトークン化してから** 判定する。
#                                                  戻り値 0 = 無効化あり / 1 = なし / 2 = クォート不整合で解析不能。
#                                                  正規表現でクォート内を落とす方式は `-m 'say "x' --no-verify -m 'y"'` のように
#                                                  クォート種が交互に現れると実フラグごと消えるため使わない（#680 Layer 1 指摘）
#   stage_all_except_secrets <repo_root> [pathspec...]
#                                                → `git add -A -- . [pathspec...]` した後、検知したパスを
#                                                  アンステージする（自動保全コミット用・作業保全は維持し
#                                                  秘密だけを履歴に乗せない）。GIT_INDEX_FILE を尊重する。
#                                                  スキャナの実行エラー（exit 2）は stderr に警告して通す
#                                                  （fail-open。保全コミット自体を止めると L-100 が崩れる）
#
# 脱出ハッチ: CLAUDE_BASE_DISABLE_SECRET_SCAN=1（命名は lib/workspace_write_guard.py に合わせた）。
# 判断基準は「スキャナ自体の不具合で通常運用が止まったときの一時回避」であり、検知を消す目的で
# 使わない（誤検知は行末 `secret-scan:ignore` か config/secret_scan_allowlist.txt で個別に扱う）。

secret_scan_path() {
  local root="$1" cand
  for cand in "$root/tools/secret_scan.py" \
              "${SECRET_SCAN_HOME:-/nonexistent}/tools/secret_scan.py" \
              "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/tools/secret_scan.py"; do
    if [ -f "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

secret_scan_run() {
  local root="$1"; shift
  [ "${CLAUDE_BASE_DISABLE_SECRET_SCAN:-0}" = "1" ] && return 0
  local scanner
  scanner=$(secret_scan_path "$root") || return 0
  ( cd "$root" && python3 "$scanner" "$@" )
}

secret_scan_join_lines() {
  # `\` + 改行を空白 1 個に置換（sed の N でファイル全体を 1 バッファに集めてから置換）
  printf '%s\n' "$1" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\\n/ /g'
}

secret_scan_target_dir() {
  local command="$1" verb="$2" joined segments seg last_cd="" dir="" arg
  joined=$(secret_scan_join_lines "$command")
  # 連結演算子・サブシェル境界で分割（pre-git-push-check.sh の scan_and_decide と同じ粒度）
  segments=$(printf '%s\n' "$joined" | sed -E -e 's/\|\|/\n/g' -e 's/&&/\n/g' -e 's/;/\n/g' -e 's/\|/\n/g' -e 's/\(/\n/g' -e 's/\)/\n/g')
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$seg" ] || continue
    if [[ "$seg" =~ ^cd[[:space:]]+(-[LPe@][[:space:]]+)*([^[:space:]]+) ]]; then
      last_cd="${BASH_REMATCH[2]}"
      continue
    fi
    if printf '%s\n' "$seg" | grep -qE "^git([[:space:]]|$)" && printf '%s\n' "$seg" | grep -qE "[[:space:]]${verb}([[:space:]]|$)"; then
      if [[ "$seg" =~ [[:space:]]-C[[:space:]]+([^[:space:]]+) ]]; then
        dir="${BASH_REMATCH[1]}"
      else
        dir="$last_cd"
      fi
      break
    fi
  done <<< "$segments"
  [ -n "$dir" ] || return 0
  # 前後の引用符を除去。変数展開・チルダは静的に解決しない（誤解決のリスクが高い）
  arg="${dir%\"}"; arg="${arg#\"}"; arg="${arg%\'}"; arg="${arg#\'}"
  if [[ "$arg" == *'$'* || "$arg" == '~'* || "$arg" == *'`'* ]]; then return 0; fi
  [ -d "$arg" ] || return 0
  ( cd "$arg" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null ) || true
}

secret_scan_commit_bypass() {
  local joined
  joined=$(secret_scan_join_lines "$1")
  SECRET_SCAN_CMD="$joined" python3 - <<'PY'
import os
import re
import shlex
import sys

cmd = os.environ.get("SECRET_SCAN_CMD", "")
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    sys.exit(2)  # クォート不整合: 静的に解析できない

# 連結演算子・サブシェル境界でセグメントに分ける（punctuation_chars=True で `&&` `||` `;` `|` `(` `)` が独立トークンになる）
segments, cur = [], []
for tok in tokens:
    if tok in ("&&", "||", ";", "|", "(", ")", ";;", "&"):
        if cur:
            segments.append(cur)
        cur = []
    else:
        cur.append(tok)
if cur:
    segments.append(cur)

SHORT_WITH_N = re.compile(r"^-[a-zA-Z]*n[a-zA-Z]*$")  # -n / -an / -nm 等（`--…` は含まない）
for seg in segments:
    if not seg or seg[0] != "git":
        # `env X=1 git commit …` / `command git …` 程度の前置きは剥がす
        while seg and (seg[0] in ("env", "command", "nice", "sudo") or "=" in seg[0] and not seg[0].startswith("-")):
            seg = seg[1:]
        if not seg or seg[0] != "git":
            continue
    args = seg[1:]
    # `git -c core.hooksPath=… <subcommand>` はサブコマンドを問わず pre-commit の置き場を差し替えられる
    for i, tok in enumerate(args):
        if tok == "-c" and i + 1 < len(args) and args[i + 1].lower().startswith("core.hookspath"):
            sys.exit(0)
        if tok.lower().startswith("-ccore.hookspath"):
            sys.exit(0)
    if "commit" not in args:
        continue
    after = args[args.index("commit") + 1:]
    for tok in after:
        if tok == "--no-verify" or SHORT_WITH_N.match(tok):
            sys.exit(0)
sys.exit(1)
PY
}

stage_all_except_secrets() {
  local root="$1"; shift
  git -C "$root" add -A -- . "$@" 2>/dev/null || true
  [ "${CLAUDE_BASE_DISABLE_SECRET_SCAN:-0}" = "1" ] && return 0
  local flagged rc=0 p err
  err=$(mktemp 2>/dev/null || echo "")
  flagged=$(secret_scan_run "$root" --staged --paths-only 2>"${err:-/dev/null}") || rc=$?
  case "$rc" in
    0) ;;
    1)
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        # 新規ファイルは index から外れ、追跡済みファイルは HEAD の内容に戻る（作業ツリーは触らない）
        git -C "$root" reset -q -- "$p" 2>/dev/null || true
      done <<< "$flagged"
      echo "[secret-scan] 秘密の疑いがあるため自動保全コミットから除外しました（作業ツリーには残っています）:" >&2
      printf '%s\n' "$flagged" | sed 's/^/[secret-scan]   /' >&2
      echo "[secret-scan] → 秘密なら .gitignore に追加して作業ツリーから退避、誤検知なら行末 secret-scan:ignore か config/secret_scan_allowlist.txt で許可してから自分でコミットしてください" >&2
      ;;
    *)
      echo "[secret-scan] ⚠ 秘密検知を実行できませんでした（exit=${rc}）。検査なしで自動保全コミットに進みます: $( [ -n "$err" ] && tail -n1 "$err" 2>/dev/null )" >&2
      ;;
  esac
  [ -n "$err" ] && rm -f "$err"
  return 0
}
