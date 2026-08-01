#!/usr/bin/env python3
"""merge_modules_yaml.py — 派生リポジトリの modules.yaml 設定を
ベース更新後の新しい modules.yaml へ引き継ぐ（apply-to-repo.sh から呼ばれる）。

apply-to-repo.sh は再適用のたびに modules.yaml をベースの最新版で無条件上書きするため、
派生側の設定（enabled: false のモジュール選択・project: セクションのプロジェクト固有値）が
ベースのブートストラップ値へ巻き戻ってしまう（enabled: Issue #196 / project: Issue #238）。
YAML 全体を再ダンプするとコメントが失われるため、該当行だけをテキスト置換する。
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pyyaml", "--quiet"])
    import yaml


# project: セクションのうち下流固有として引き継ぐキーと、引き継ぎ対象外とみなす値
# （ベースのブートストラップ前プレースホルダ・未設定の空文字は下流固有値ではない）
_PROJECT_KEYS = ("name", "repo", "timezone")
_PLACEHOLDER_VALUES = {"{{PROJECT_NAME}}", "{{REPO_SLUG}}", ""}


def disabled_modules(path: Path) -> set[str]:
    if not path.exists():
        return set()
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return {
        name
        for name, mod in (data.get("modules") or {}).items()
        if isinstance(mod, dict) and mod.get("enabled", True) is False
    }


def project_overrides(path: Path) -> dict[str, str]:
    """下流 modules.yaml の project: セクションから、引き継ぐべき実値だけを返す。

    プレースホルダ（未 bootstrap）・空文字は下流固有値ではないため除外する。
    """
    if not path.exists():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    project = data.get("project") or {}
    if not isinstance(project, dict):
        return {}
    overrides: dict[str, str] = {}
    for key in _PROJECT_KEYS:
        val = project.get(key)
        if isinstance(val, str) and val.strip() and val not in _PLACEHOLDER_VALUES:
            overrides[key] = val
    return overrides


def apply_project_overrides(text: str, overrides: dict[str, str]) -> tuple[str, list[str]]:
    """new の project: ブロック内の該当行の値を下流値へ置換する（コメント保持）。

    project.name / repo / timezone はいずれも `"..."` 形式のクォート文字列で、
    行コメントは値クォートの後ろにあるため、値部分だけを置換すればコメントは残る。
    トップレベル project: ブロックに限定して置換し、modules 配下の同名キーを誤爆しない。
    """
    if not overrides:
        return text, []
    block_m = re.search(r"^project:\n(?:^[ \t].*\n|^[ \t]*\n)*", text, re.MULTILINE)
    if not block_m:
        return text, []
    block = block_m.group(0)
    new_block = block
    patched: list[str] = []
    for key, val in overrides.items():
        key_re = re.compile(rf'(^  {re.escape(key)}:[ \t]*)"[^"]*"', re.MULTILINE)
        replaced, count = key_re.subn(lambda m, v=val: m.group(1) + '"' + v + '"', new_block, count=1)
        if count:
            new_block = replaced
            patched.append(key)
    if new_block != block:
        text = text[: block_m.start()] + new_block + text[block_m.end() :]
    return text, patched


def main(old_path: str, new_path: str) -> None:
    old = Path(old_path)
    new = Path(new_path)
    names = disabled_modules(old)
    overrides = project_overrides(old)
    if not names and not overrides:
        return

    new_data = yaml.safe_load(new.read_text(encoding="utf-8")) or {}
    modules = new_data.get("modules") or {}
    text = new.read_text(encoding="utf-8")
    patched = []
    for name in sorted(names):
        mod = modules.get(name)
        if mod is None:
            continue  # ベース側で廃止済みのモジュール
        if mod.get("required"):
            continue  # required は無効化不可（prune_modules.py と同一ポリシー）
        block_re = re.compile(
            rf"(^  {re.escape(name)}:\n(?:^ {{4}}.*\n)*?^ {{4}}enabled: )true(\n)",
            re.MULTILINE,
        )
        new_text, count = block_re.subn(r"\1false\2", text, count=1)
        if count:
            text = new_text
            patched.append(name)

    text, proj_patched = apply_project_overrides(text, overrides)

    if patched or proj_patched:
        new.write_text(text, encoding="utf-8")
    if patched:
        print(f"[merge_modules_yaml] 派生側の enabled:false を引き継ぎました: {', '.join(patched)}")
    if proj_patched:
        print(f"[merge_modules_yaml] 派生側の project: 設定を引き継ぎました: {', '.join(proj_patched)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: merge_modules_yaml.py <old_modules.yaml> <new_modules.yaml>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
