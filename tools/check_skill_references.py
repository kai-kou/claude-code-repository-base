#!/usr/bin/env python3
"""skill-audit スキル向け: SKILL.md / commands / ルール本体からの参照実在チェック（機械検証）

.claude/skills/*/SKILL.md・.claude/commands/*.md、および docs/rules 配下のルール本体
（#349 で対象拡張）の本文中で言及されるファイルパス（tools/*.py・docs/rules/*.md・
.claude/**・content/** 等）を正規表現で抽出し、リポジトリ上に実在するかを機械的に検証する。
併せて SKILL.md / commands の行数を集計し、肥大化閾値（既定 500 行）超過を報告する
（ルール本体は行数の性質が違うため肥大化判定の対象外）。

除外規約（#350・**明示マーカーのみ**）:
  ① 行末に <!-- refcheck:ignore --> を置くとその行の参照を検証しない
     （実行時生成物・ローカル専用ファイル・「存在しない」と明示した否定文脈・歴史的言及・
       出自プロジェクト由来のファイル名）
  ② <!-- refcheck:ignore-start --> 〜 <!-- refcheck:ignore-end --> で囲んだ範囲を検証しない
     （長い表・一覧をまとめて外すとき）
  自然言語の注意書き（「出自プロジェクトの実例」等）は **除外根拠にしない**。節スコープの
  一括除外は同じ節の実在する現役参照まで検証対象から外し、本チェックが防ぐべき rename/削除の
  regression を見逃すため（実測でファイル全体の検証が無効化された事例あり・#350）。

目視での参照実在チェック（陳腐化リンクの見落とし）を機械化するためのツール。
SSOT: .claude/skills/skill-audit/SKILL.md

使い方:
  python3 tools/check_skill_references.py               # 人間向けレポート
  python3 tools/check_skill_references.py --json         # 機械可読 JSON
  python3 tools/check_skill_references.py --bloat-threshold 500
  python3 tools/check_skill_references.py --skip-rules   # ルール本体の検証を外す
  python3 tools/check_skill_references.py --self-test    # 除外規約の自己テスト

終了コード:
  0 = リンク切れ・肥大化なし
  1 = リンク切れまたは肥大化ファイルを検出
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# バッククォート内のパスらしき文字列を抽出する（拡張子つき or 既知プレフィックスで始まる）
PATH_PATTERN = re.compile(
    r"`((?:tools|docs|content|\.claude|config)/[A-Za-z0-9_./\-]+\.(?:py|sh|md|json|ya?ml))`"
)

TARGET_GLOBS = [
    ".claude/skills/*/SKILL.md",
    ".claude/skills/*/reference.md",
    ".claude/commands/*.md",
]

# ルール本体（docs/rules）間の相互参照も検証する。肥大化チェックは対象外
# （ルールは SKILL.md と行数の性質が違うため。#349）
RULES_TARGET_GLOBS = [
    "docs/rules/*.md",
    "docs/rules/lessons/*.md",
]

# --- 除外規約（#349・偽陽性が 38 件中 37 件を占めたため必須要件）------------------
# 除外は **明示マーカーのみ**。自然言語の注意書き（「出自プロジェクトの実例」等）を機械的な
# 除外根拠にはしない: 節スコープ丸ごと除外は、同じ節にある **実在する現役の参照** まで
# 検証対象から外してしまい（実測でファイル全体の検証が無効化された事例あり）、
# 本チェックが防ぐべき rename/削除の regression を見逃す（#350 のセルフレビュー指摘）。
# ① 行マーカー: その行の参照を検証しない
IGNORE_LINE_MARKER = "<!-- refcheck:ignore -->"
# ② ブロックマーカー: start と end で囲んだ範囲の参照を検証しない（長い表・一覧向け）
IGNORE_BLOCK_START = "<!-- refcheck:ignore-start -->"
IGNORE_BLOCK_END = "<!-- refcheck:ignore-end -->"


def collect_target_files() -> list[Path]:
    files: list[Path] = []
    for pattern in TARGET_GLOBS:
        files.extend(sorted(REPO_ROOT.glob(pattern)))
    return files


def collect_rules_files() -> list[Path]:
    files: list[Path] = []
    for pattern in RULES_TARGET_GLOBS:
        files.extend(sorted(REPO_ROOT.glob(pattern)))
    return files


PLACEHOLDER_TOKENS = ("YYYY", "XXXX", "{", "<", "__")


def extract_referenced_paths(text: str) -> set[str]:
    lines = text.splitlines()
    referenced: set[str] = set()
    in_ignore_block = False
    for line in lines:
        if IGNORE_BLOCK_START in line:
            in_ignore_block = True
            continue
        if IGNORE_BLOCK_END in line:
            in_ignore_block = False
            continue
        if in_ignore_block or IGNORE_LINE_MARKER in line:
            continue
        for match in PATH_PATTERN.finditer(line):
            ref = match.group(1)
            if any(tok in ref for tok in PLACEHOLDER_TOKENS):
                continue
            referenced.add(ref)
    return referenced


def check_file(path: Path, bloat_threshold: int, *, check_bloat: bool = True) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    # wc -l と一致させる（改行文字数そのもの・末尾改行の有無で +1 しない）
    line_count = text.count("\n")
    referenced = extract_referenced_paths(text)
    missing = sorted(
        ref for ref in referenced if not (REPO_ROOT / ref).exists()
    )
    return {
        "file": str(path.relative_to(REPO_ROOT)),
        "line_count": line_count,
        "bloated": check_bloat and line_count > bloat_threshold,
        "referenced_count": len(referenced),
        "missing_references": missing,
    }


SELF_TEST_CASES = [
    # (説明, 本文, 期待される抽出結果)
    (
        "通常の参照は抽出される",
        "本文で `docs/rules/nonexistent-xyz.md` を参照する\n",
        {"docs/rules/nonexistent-xyz.md"},
    ),
    (
        "行マーカーの行は抽出されない",
        "生成物なので検証しない `tools/generated-xyz.json` <!-- refcheck:ignore -->\n",
        set(),
    ),
    (
        "行マーカーは同じ行だけに効く（隣の行を巻き込まない）",
        "- `tools/example-xyz.py` <!-- refcheck:ignore -->\n"
        "- `docs/rules/nonexistent-xyz.md`\n",
        {"docs/rules/nonexistent-xyz.md"},
    ),
    (
        "ブロックマーカーで囲んだ範囲は抽出されない",
        "<!-- refcheck:ignore-start -->\n- `tools/example-xyz.py`\n"
        "- `tools/example2-xyz.py`\n<!-- refcheck:ignore-end -->\n",
        set(),
    ),
    (
        "ブロックマーカーは end 以降に効かない（閉じ忘れ以外で漏れない）",
        "<!-- refcheck:ignore-start -->\n- `tools/example-xyz.py`\n"
        "<!-- refcheck:ignore-end -->\n- `docs/rules/nonexistent-xyz.md`\n",
        {"docs/rules/nonexistent-xyz.md"},
    ),
    (
        "自然言語の注意書き（出自プロジェクトの実例）は除外根拠にならない",
        "## 例示節\n\n> ⚠️ 以下は **出自プロジェクト（動画制作）の実例**。\n\n"
        "- `docs/rules/nonexistent-xyz.md`\n",
        {"docs/rules/nonexistent-xyz.md"},
    ),
]


def run_self_test() -> int:
    """除外規約が「検出すべきものを検出し、除外すべきものだけ除外する」ことを検証する。

    除外規約が過剰になると本チェック自体が無音化するため、機械的に固定する（#349/#350）。
    """
    failures = 0
    for label, text, expected in SELF_TEST_CASES:
        actual = extract_referenced_paths(text)
        if actual == expected:
            print(f"  ✅ {label}")
        else:
            failures += 1
            print(f"  ❌ {label}\n     期待: {sorted(expected)}\n     実際: {sorted(actual)}")
    print(f"\n{'✅ self-test PASS' if not failures else f'❌ self-test FAIL: {failures} 件'}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="機械可読 JSON で出力")
    parser.add_argument(
        "--bloat-threshold",
        type=int,
        default=500,
        help="肥大化と判定する行数閾値（既定 500）",
    )
    parser.add_argument(
        "--skip-rules",
        action="store_true",
        help="docs/rules 間の参照検証をスキップする（既定は検証する・#349）",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="除外規約の自己テストを実行する（過剰除外による無音化の防止）",
    )
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    skill_files = collect_target_files()
    rules_files = [] if args.skip_rules else collect_rules_files()
    results = [check_file(p, args.bloat_threshold) for p in skill_files]
    results += [
        check_file(p, args.bloat_threshold, check_bloat=False) for p in rules_files
    ]
    broken = [r for r in results if r["missing_references"]]
    bloated = [r for r in results if r["bloated"]]

    if args.json:
        print(json.dumps({"results": results, "broken": broken, "bloated": bloated}, ensure_ascii=False, indent=2))
    else:
        print(
            f"検査対象: {len(results)} ファイル"
            f"（スキル/コマンド {len(skill_files)} + ルール {len(rules_files)}）"
        )
        if broken:
            print(f"\n❌ リンク切れ検出: {len(broken)} ファイル")
            for r in broken:
                print(f"  - {r['file']}: {', '.join(r['missing_references'])}")
        else:
            print("✅ リンク切れなし")
        if bloated:
            print(f"\n⚠️ 肥大化検出（>{args.bloat_threshold} 行）: {len(bloated)} ファイル")
            for r in bloated:
                print(f"  - {r['file']}: {r['line_count']} 行")
        else:
            print(f"✅ 肥大化なし（閾値 {args.bloat_threshold} 行）")

    return 1 if (broken or bloated) else 0


if __name__ == "__main__":
    sys.exit(main())
