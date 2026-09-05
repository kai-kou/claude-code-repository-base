#!/usr/bin/env python3
"""作業領域の外へ書き込む Bash / ホーム配下の Claude 設定領域を触る Bash を、承認プロンプトになる前に差し戻すガード。

背景（実測・Issue #578）:
  クラウド実行環境には bwrap / sandbox-exec が存在せず（`command -v bwrap` = MISSING・`Seccomp: 0`）、
  `.claude/settings.json` の `sandbox.enabled: true` は起動できない。したがってクラウドでの Bash 承認可否は
  `permissions.*` の静的ルールと auto モードの classifier だけで決まる。公式仕様どおり classifier は
  「作業ディレクトリ・セッション一時ディレクトリの外への書き込み / 削除」を自動承認しないため、
  無人ルーティン（scheduled trigger）がそういうコマンドを出すと **誰も承認しないまま無限停止** する。

  実測（headless プローブ・`claude -p --permission-mode auto`）:
    - `mkdir -p /tmp/<作業ツリー外>/x && echo hi > /tmp/<作業ツリー外>/x/a.txt` → permission_denials に記録
    - `mkdir -p /tmp/<作業ツリー外>/y && rm -rf /tmp/<作業ツリー外>/y`         → permission_denials に記録
    - 作業ディレクトリ内・セッション scratchpad 配下の書き込み                 → 記録なし（通る）

  本ガードはプロンプトに落ちる前にブロックし、代替（セッション scratchpad / ネイティブ Read・Grep ツール）を
  案内する。ブロックは **ツール失敗として Claude に返る** ため、無人セッションでも停止せず自己修正できる。

射程と限界（過信しないこと）:
  - コマンド名の列挙型で、`python3 -c "open('/etc/x','w')"` のような任意コード経由は塞げない
    （`pre-tool-use-router.sh` の機密ファイルガードと同じ設計上の限界。残余リスクはコンテナ隔離が引き受ける）
  - 解決できない変数（外部 env 由来）を含むパスは判定不能として素通りさせる（誤ブロックを避ける。
    同一コマンド内の `NAME=value` 代入は解決する）
  - 目的は「無人セッションの停止防止」であって権限の代替ではない。`permissions.deny` の保護とは独立

トグル: `CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1` で無効化する。

入出力:
  stdin  : PreToolUse フックの JSON（`tool_input.command` / `cwd` / `session_id` を読む）
  stdout : ブロックする場合のみ理由文（複数行）
  exit   : 0 = 問題なし / 1 = ブロック（呼び出し側の router が exit 2 に変換する）

自己テスト: `python3 .claude/hooks/lib/workspace_write_guard.py --self-test`
回帰テスト: `bash tools/test_workspace_write_guard.sh`
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

# 非フラグ引数のすべてが書き込み / 削除対象になるコマンド
WRITE_ALL_ARGS = {
    "rm", "rmdir", "mkdir", "touch", "tee", "truncate", "shred", "unlink",
    "chmod", "chown", "chgrp",
}
# 最後の非フラグ引数が書き込み先になるコマンド
WRITE_LAST_ARG = {"cp", "mv", "ln", "install", "rsync"}
# フラグの値が書き込み先になるコマンド（GNU の `-t DIR` / ダウンロード先指定）
DEST_VALUE_FLAGS = {
    "cp": ("-t", "--target-directory"),
    "mv": ("-t", "--target-directory"),
    "install": ("-t", "--target-directory"),
    "rsync": ("--target-directory",),
    "curl": ("-o", "--output", "--output-dir"),
    "wget": ("-O", "--output-document", "-P", "--directory-prefix"),
}
# 実コマンドの前に置かれ、読み飛ばしてよいラッパー
COMMAND_WRAPPERS = {"sudo", "env", "nice", "ionice", "command", "exec", "builtin", "time", "timeout"}
# セグメント区切りとして扱うトークン（`&>` はリダイレクトなので含めない）
SEGMENT_SEPARATORS = {";", "&", "&&", "|", "||"}
# リダイレクト演算子（`>` `>>` `2>` `&>` `>|` `1>>` 等）
_REDIRECT_OP = re.compile(r"^[0-9]*&?>{1,2}\|?$")
# heredoc の開始（`<<EOF` / `<<'EOF'` / `<<-"EOF"`）
_HEREDOC_START = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
# 同一コマンド文字列内の変数代入（`WORK=/tmp/foo` 形式・値にスペースを含まないもののみ）
_ASSIGNMENT = re.compile(r"(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=([^\s;&|)]+)")
# 未解決の変数参照
_UNRESOLVED_VAR = re.compile(r"\$\{?[A-Za-z_(]")


def _strip_heredocs(command: str) -> str:
    """heredoc の本文を解析対象から除く。

    ドキュメントやスクリプトを heredoc で書き込むとき、本文中に例示として現れるパスは実際の
    ファイル操作ではない。除かないと文書を書くたびに誤ブロックする（導入直後に実発生）。

    2 つの安全策を持つ:
      - 同一行に複数の heredoc（`cat <<A <<B`）がある場合、宣言順に全ての本体を除く
      - **終端デリミタが見つからないまま行末に達したら、読み飛ばした行を解析対象へ戻す**
        （fail-open にすると、終端漏れした heredoc 以降の実コマンドが丸ごと不可視になる）
    """
    lines = command.split("\n")
    kept: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        kept.append(line)
        pending = [m.group(2) for m in _HEREDOC_START.finditer(line)]
        index += 1
        if not pending:
            continue
        body_start = index
        while pending and index < len(lines):
            if lines[index].strip() == pending[0]:
                pending.pop(0)
            index += 1
        if pending:
            # 未終端: 読み飛ばした範囲を解析対象に戻す（安全側）
            kept.extend(lines[body_start:])
            index = len(lines)
    return "\n".join(kept)


def _expand_assignments(command: str) -> str:
    """同一コマンド文字列内の `NAME=value` 代入を、その後の `$NAME` / `${NAME}` へ展開する。

    `WORK=/tmp/demo; rm -rf $WORK` のような一時変数経由のパスを静的に解決するための最小実装。
    """
    values: dict[str, str] = {}
    for name, value in _ASSIGNMENT.findall(command):
        for known, known_value in values.items():
            value = value.replace(f"${{{known}}}", known_value).replace(f"${known}", known_value)
        values[name] = value
    if not values:
        return command
    expanded = command
    # 長い名前から置換する（`$WORK_DIR` を `$WORK` で壊さない）
    for name in sorted(values, key=len, reverse=True):
        expanded = expanded.replace(f"${{{name}}}", values[name]).replace(f"${name}", values[name])
    return expanded


def _tokenize_line(line: str) -> list[str]:
    """1 行をクォートを尊重してトークン化する。

    生文字列に正規表現でセグメント分割をかけると、`curl "https://x/a?b=1&c=2" -o out` のように
    クォート内へ区切り文字を含む引数でコマンドが分断され、以降の解析が丸ごと落ちる。
    `punctuation_chars=True` の shlex は `;` `&&` `||` `|` `>` `>>` を独立トークンにするため、
    クォート内の同じ文字と区別できる。
    """
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        # クォートが閉じていない等。判定不能として空を返す（素通り）
        return []


def _segments(command: str) -> list[list[str]]:
    """コマンド文字列を「1 コマンド = 1 トークン列」のセグメントへ分ける（行またぎも区切る）。"""
    result: list[list[str]] = []
    for line in command.split("\n"):
        current: list[str] = []
        for token in _tokenize_line(line):
            if token in SEGMENT_SEPARATORS:
                if current:
                    result.append(current)
                current = []
            else:
                current.append(token)
        if current:
            result.append(current)
    return result


def _resolve(path: str, cwd: str | None, home: str) -> str | None:
    """パス様トークンを絶対パスへ正規化する。解決できないものは None を返す。

    シンボリックリンクも解決する（作業ディレクトリ内のリンクが外部を指すケースを取りこぼさない）。
    """
    if not path or _UNRESOLVED_VAR.search(path):
        return None
    if path.startswith("~"):
        path = home + path[1:]
    if not path.startswith("/"):
        if cwd is None:
            return None  # `cd` 先が解決できないセグメント。判定不能として素通りさせる
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def _under(path: str, base: str) -> bool:
    return path == base or path.startswith(base.rstrip("/") + "/")


def _is_device_sink(path: str) -> bool:
    """`/dev/null` 等の擬似デバイスは「作業領域外への書き込み」に数えない。

    `cmd 2>/dev/null` は日常的に使われ、承認プロンプトにもならない（実ファイルを作らない）。
    除外しないと本ガードが通常運用を止める（導入直後に実発生）。`realpath` 後に
    `/proc/self/fd/…` へ解決される `/dev/stdout` 等も拾えるようプレフィックスで判定する。
    """
    return path.startswith("/dev/") or re.match(r"^/proc/(self|[0-9]+)/fd/", path) is not None


def _session_tmp_ok(path: str, session_id: str) -> bool:
    """ハーネスが払い出す **このセッションの** scratchpad 領域かどうか。

    `/tmp/claude-<N>/<project>/<session-id>/...` という構造なので、session_id まで一致させる。
    緩いプレフィックス一致（`/tmp/claude-` で始まれば何でも可）にすると、他セッションの
    scratchpad の削除や、実在しない自作パスまで安全扱いになる。
    """
    if not path.startswith("/tmp/claude-"):
        return False
    if not session_id:
        # session_id が渡らない環境では、セッション領域を安全基点に加えない（安全側）
        return False
    return re.match(rf"^/tmp/claude-[^/]*/[^/]+/{re.escape(session_id)}(/|$)", path) is not None


def _command_index(tokens: list[str]) -> int | None:
    """先頭の環境変数代入とラッパー（sudo / env / timeout 等）を読み飛ばしてコマンド名の位置を返す。"""
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if "=" in token and not token.startswith("-") and not token.startswith("/"):
            index += 1
            continue
        if os.path.basename(token) in COMMAND_WRAPPERS:
            index += 1
            # ラッパーのフラグと数値引数（`timeout 300 cmd` の 300）を読み飛ばす
            while index < len(tokens) and (tokens[index].startswith("-") or tokens[index].isdigit()):
                index += 1
            continue
        return index
    return None


def _strip_redirection_args(tokens: list[str]) -> list[str]:
    """リダイレクト演算子とその直後の宛先をトークン列から除く（宛先は別途 targets へ入れる）。"""
    cleaned: list[str] = []
    skip_next = False
    for token in tokens:
        if skip_next:
            skip_next = False
            continue
        if _REDIRECT_OP.match(token):
            skip_next = True
            continue
        cleaned.append(token)
    return cleaned


def _write_targets(tokens: list[str]) -> list[str]:
    """セグメントのトークン列から、書き込み / 削除の対象になるパス様トークンを抽出する。"""
    if not tokens:
        return []
    targets: list[str] = []

    # リダイレクト先（`>` `>>` `2>` `&>` `>|` の直後）
    for i, token in enumerate(tokens):
        if _REDIRECT_OP.match(token) and i + 1 < len(tokens):
            targets.append(tokens[i + 1])

    index = _command_index(tokens)
    if index is None:
        return targets
    name = os.path.basename(tokens[index])
    args = _strip_redirection_args(tokens[index + 1:])

    # 値が書き込み先になるフラグ（`-t DIR` / `--target-directory=DIR` / `curl -o FILE`）
    dest_flags = DEST_VALUE_FLAGS.get(name, ())
    flag_dests: list[str] = []
    operands: list[str] = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg.startswith("-") and arg != "-":
            matched_value = None
            consumed = 1
            for flag in dest_flags:
                if arg == flag and i + 1 < len(args):
                    matched_value, consumed = args[i + 1], 2
                    break
                if arg.startswith(flag + "="):
                    matched_value = arg[len(flag) + 1:]
                    break
            if matched_value is not None:
                flag_dests.append(matched_value)
            i += consumed
            continue
        operands.append(arg)
        i += 1

    targets.extend(flag_dests)

    if name == "dd":
        targets.extend(a[len("of="):] for a in args if a.startswith("of="))
    elif name == "sed" and any(a.startswith("-i") and not a.startswith("--") for a in args):
        # `sed -i 's/a/b/' file...` — 最初の非フラグ引数はスクリプト、残りが書き換え対象
        targets.extend(operands[1:])
    elif name in WRITE_ALL_ARGS:
        targets.extend(operands)
    elif name in WRITE_LAST_ARG and operands and not flag_dests:
        targets.append(operands[-1])
    return targets


def _path_like(tokens: list[str]) -> list[str]:
    """`/` か `~` で始まるトークン（パス様トークン）。読み取りも対象にする判定用。"""
    return [t for t in tokens if t.startswith("/") or t.startswith("~")]


def analyze(command: str, cwd: str, home: str, session_id: str = "") -> list[str]:
    """ブロック理由のリストを返す（空なら問題なし）。"""
    reasons: list[str] = []
    expanded = _expand_assignments(_strip_heredocs(command))
    home_claude = os.path.realpath(os.path.join(home, ".claude"))
    cwd = os.path.realpath(cwd)
    tmpdir = os.environ.get("TMPDIR", "").strip()
    safe_bases = [cwd] + ([os.path.realpath(tmpdir)] if tmpdir else [])
    # `cd` でカレントディレクトリが変わったら以降のセグメントの基点も変える（None = 解決不能）
    current_cwd: str | None = cwd

    def is_safe(path: str) -> bool:
        return (
            any(_under(path, base) for base in safe_bases)
            or _session_tmp_ok(path, session_id)
            or _is_device_sink(path)
        )

    for tokens in _segments(expanded):
        # (1) ホーム配下の Claude 領域への Bash アクセス（読み書き問わず）
        for token in _path_like(tokens):
            resolved = _resolve(token, current_cwd, home)
            if resolved is None:
                continue
            if _under(resolved, home_claude) and not is_safe(resolved):
                reasons.append(
                    f"ホーム配下の Claude 領域への Bash アクセス: {resolved}\n"
                    "  → ネイティブの Read / Grep / Edit ツールを使うこと"
                    "（PermissionRequest フックが自動承認するため無人でも止まらない）。"
                )

        # (2) 作業ディレクトリ・セッション一時領域の外への書き込み / 削除
        for token in _write_targets(tokens):
            resolved = _resolve(token, current_cwd, home)
            if resolved is None:
                continue
            if is_safe(resolved) or _under(resolved, home_claude):
                continue  # 後者は (1) で報告済み
            reasons.append(
                f"作業領域の外への書き込み / 削除: {resolved}\n"
                "  → 一時作業はセッション scratchpad（システムプロンプトが提示するパス）か"
                "リポジトリ内の作業ディレクトリで行うこと。"
            )

        # (3) `cd` の効果を次のセグメントへ引き継ぐ
        index = _command_index(tokens)
        if index is not None and os.path.basename(tokens[index]) == "cd":
            operands = [t for t in tokens[index + 1:] if not t.startswith("-")]
            current_cwd = _resolve(operands[0], current_cwd, home) if operands else home

    # 同一理由の重複を除く（順序は維持）
    return list(dict.fromkeys(reasons))


def _self_test() -> int:
    cwd, home, sid = "/home/user/demo-repo", "/root", "sess-1"
    cases: list[tuple[bool, str]] = [
        # (ブロックされるべきか, コマンド)
        (True, 'WORK=/tmp/demo-out; rm -rf $WORK; mkdir -p $WORK/x'),
        (True, 'cp /root/.claude/projects/a/tool-results/r.txt ./page1.json'),
        (True, 'cp -t /tmp/demo-out file1.txt file2.txt'),
        (True, 'cp --target-directory=/tmp/demo-out file1.txt'),
        (True, 'curl -o /tmp/demo-out/report.json https://example.com/r.json'),
        (True, 'wget -O /tmp/demo-out/a.bin https://example.com/a.bin'),
        (True, 'sed -i "s/a/b/" /etc/demo.conf'),
        (True, 'dd if=/dev/zero of=/tmp/demo-out/blob bs=1M count=1'),
        (True, 'somecmd 2> /tmp/demo-out/err.log'),
        (True, 'echo hi >| /tmp/demo-out/a.txt'),
        (True, 'cd /tmp/other-place && rm -rf temp_output'),
        (True, 'sudo rm -rf /tmp/demo-out/x'),
        (True, 'rm -rf /tmp/claude-0/proj/other-session/scratchpad'),
        (True, 'curl "https://x.example/a?b=1&c=2" -o /tmp/demo-out/report.json'),
        (True, 'cat <<EOF\nintro\nrm -rf /tmp/demo-out\n'),  # 未終端 heredoc は解析対象へ戻す
        (False, f'mkdir -p /tmp/claude-0/proj/{sid}/scratchpad && echo hi > /tmp/claude-0/proj/{sid}/scratchpad/a.txt'),
        (False, 'echo hi > ./notes.md'),
        (False, 'rm -rf node_modules'),
        (False, 'cp /usr/share/doc/readme ./readme'),
        (False, 'grep -rn foo /usr/share/doc'),
        (False, 'cat .claude/settings.json'),
        (False, 'cd docs && rm -rf build'),
        (False, 'curl "https://x.example/a?b=1&c=2" -o ./report.json'),
        (False, 'cat > docs/note.md <<EOF\n例: rm -rf /tmp/demo-out は承認プロンプトになる\nEOF'),
        (False, 'mkdir -p "$EXTERNAL_BASE/x"'),
        (False, 'some-check 2>/dev/null | head -3'),
        (False, 'echo hi > /dev/null'),
        (False, 'dd if=/dev/zero of=/dev/null bs=1M count=1'),
    ]
    failures = 0
    for expect_block, command in cases:
        actual = bool(analyze(command, cwd, home, sid))
        if actual != expect_block:
            failures += 1
            print(f"  NG 期待={'BLOCK' if expect_block else 'ALLOW'} 実際={'BLOCK' if actual else 'ALLOW'}: {command!r}")
    print(f"[workspace_write_guard --self-test] PASS={len(cases) - failures} FAIL={failures}")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return _self_test()
    if os.environ.get("CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD") == "1":
        return 0
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # 入力が読めないときは素通り（フックで作業を止めない）
    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command.strip():
        return 0
    cwd = os.path.normpath(payload.get("cwd") or os.getcwd())
    home = os.path.normpath(os.path.expanduser("~"))
    session_id = payload.get("session_id") or os.environ.get("CLAUDE_CODE_SESSION_ID", "")

    reasons = analyze(command, cwd, home, session_id)
    if not reasons:
        return 0

    print("BLOCK: 承認プロンプトになるコマンドです（無人ルーティンが停止するため事前に差し戻します）")
    for reason in reasons:
        print(f"- {reason}")
    print(
        "背景: クラウドでは Bash サンドボックスが起動できず、作業ディレクトリ外への書き込みは "
        "auto モードの classifier が自動承認しない（Issue #578・実測）。"
    )
    print(
        "どうしても外部パスが必要な場合のみ "
        "`CLAUDE_BASE_DISABLE_WORKSPACE_WRITE_GUARD=1` を付けて実行する"
        "（対話セッションでは承認プロンプトが出る前提で使うこと）。"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
