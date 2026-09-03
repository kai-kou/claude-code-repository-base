#!/usr/bin/env python3
"""再帰 grep に deny 対象の除外オプションを付与する（PreToolUse `updatedInput` の生成器）。

`pre-tool-use-router.sh` から呼ばれる。stdin にコマンド文字列、argv[1] に挿入したい
除外オプション列（`--exclude='...' --exclude-dir='...'` の形）を受け取り、書き換えが必要なら
書き換え後のコマンドを stdout に出力する。書き換え不要・解析不能なら何も出力しない
（呼び出し側は出力が空なら「据え置き」と解釈する）。

安全側の設計（誤爆でコマンドの意味を変えないことを最優先する）:
  - **heredoc（`<<`）・コマンド置換（`$(` / バッククォート）・プロセス置換を含むコマンドは
    まるごと解析対象外**にする。これらの内側のテキストは「実行されるコマンド」ではなく
    「書き出される中身」でありうるため、字面の `grep` を書き換えるとファイル内容が化ける。
  - 分割はクォート状態を追跡し、**クォートの外にある区切り**（`;` `&&` `||` `|` `&` 改行）でのみ行う。
    検索パターン内の `;` や `--exclude` という語で誤判定しない。
  - 対象は **セグメントの先頭語が `grep`** のものだけ。`git grep` / `rg` / パイプ後段の
    `... | grep foo` は先頭語が違うか非再帰なので自然に対象外になる。
  - クォートが閉じていない等、解析しきれない入力は書き換えない。
"""

import sys

# 値を次トークンに取るオプション（次トークンをオペランドと誤認しないため）
_VALUE_OPTS = {
    "-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "--regexp", "--file",
    "--max-count", "--after-context", "--before-context", "--context",
    "--directories", "--devices", "--binary-files", "--color", "--colour",
    "--label", "--include", "--exclude", "--exclude-dir", "--exclude-from",
}
# 解析を諦めるべき構文（内側のテキストが「実行されるコマンド」とは限らない）
_UNPARSEABLE = ("<<", "$(", "`", "<(", ">(")


def split_segments(cmd):
    """クォート外の区切りで (本文, 区切り) の列に分割する。解析不能なら None を返す。"""
    segments = []
    buf = []
    quote = None
    i = 0
    while i < len(cmd):
        ch = cmd[i]
        if quote is not None:
            buf.append(ch)
            if ch == quote:
                quote = None
            elif ch == "\\" and quote == '"' and i + 1 < len(cmd):
                buf.append(cmd[i + 1])
                i += 1
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < len(cmd):
            buf.append(ch)
            buf.append(cmd[i + 1])
            i += 2
            continue
        two = cmd[i:i + 2]
        if two in ("&&", "||"):
            segments.append(("".join(buf), two))
            buf = []
            i += 2
            continue
        if ch in (";", "|", "&", "\n"):
            segments.append(("".join(buf), ch))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if quote is not None:
        return None
    segments.append(("".join(buf), ""))
    return segments


def is_recursive_grep(tokens):
    """grep のオプション列に -r / -R（または --recursive 系）があるか。"""
    skip_next = False
    for token in tokens:
        if skip_next:
            skip_next = False
            continue
        if token == "--":
            return False
        if not token.startswith("-") or token == "-":
            # 最初のオペランド（検索パターン）に到達したら以降は見ない
            return False
        name = token.split("=", 1)[0]
        if name in _VALUE_OPTS and "=" not in token:
            skip_next = True
            continue
        if token.startswith("--"):
            if name in ("--recursive", "--dereference-recursive"):
                return True
            continue
        if "r" in token[1:] or "R" in token[1:]:
            return True
    return False


def has_exclude(tokens):
    """既に絞り込みが指定されているか。

    `--include` も対象に含める。走査対象が明示的に絞られている呼び出しに除外を足すのは
    冗長なうえ、コマンドを書き換えた分だけ権限判定をやり直させることになるため触らない。
    """
    for token in tokens:
        if token == "--":
            return False
        if token.split("=", 1)[0] in (
            "--exclude", "--exclude-dir", "--exclude-from", "--include", "--include-dir",
        ):
            return True
    return False


def rewrite_segment(segment, excludes):
    stripped = segment.lstrip()
    if not (stripped == "grep" or stripped.startswith("grep ")):
        return segment
    tokens = stripped.split()[1:]
    if not is_recursive_grep(tokens) or has_exclude(tokens):
        return segment
    lead = segment[: len(segment) - len(stripped)]
    return lead + "grep " + excludes + stripped[len("grep"):]


def normalize(cmd, excludes):
    """書き換えたコマンドを返す。書き換え不要・解析不能なら None。"""
    if not excludes.strip():
        return None
    if any(marker in cmd for marker in _UNPARSEABLE):
        return None
    segments = split_segments(cmd)
    if segments is None:
        return None
    rewritten = "".join(rewrite_segment(text, excludes) + sep for text, sep in segments)
    return rewritten if rewritten != cmd else None


def main():
    excludes = sys.argv[1] if len(sys.argv) > 1 else ""
    command = sys.stdin.read()
    result = normalize(command, excludes)
    if result is not None:
        sys.stdout.write(result)


if __name__ == "__main__":
    main()
