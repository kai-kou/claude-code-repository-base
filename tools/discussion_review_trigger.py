#!/usr/bin/env python3
"""discussion_review_trigger.py — Layer 2 議論型レビューの自動トリガー（判定器）。

PR の差分行数またはラベルに基づいて Layer 2 議論型レビューの要否を判定する。
pr-review-watcher スキルが PR 作成後に呼び出す（Issue #97）。

既定（ネイティブ経路・Issue #193）: トリガー該当時は「実行プラン JSON」を stdout に出力して
終了する。呼び出し元のエージェントがこのプランを使って discussion-review スキル
（ネイティブ Agent Teams）を実行する。本スクリプトはサブプロセスを起動しない。

--legacy 指定時（フォールバック）: 旧経路（run_discussion_review.py = claude -p 駆動）を
サブプロセスとして直接起動する。ネイティブ経路が成立しない場合のみ使う。

トリガー条件:
  - 差分行数（追加 + 削除）が TRIGGER_DIFF_LINES（300行）以上
  - PR ラベルに TRIGGER_LABELS（type:security / type:breaking-change）が含まれる

## クラウド環境での使い方（gh CLI 不可・MCP ツールで事前取得必須）

クラウド実行環境では gh CLI の GraphQL/REST が無効なため、エージェントが
mcp__github__pull_request_read で取得した値を引数として渡す:

  python3 tools/discussion_review_trigger.py \\
      --pr 42 \\
      --diff-lines 450 \\
      --labels "type:improvement" \\
      --changed-files "tools/foo.py,docs/bar.md"

## ローカル環境での使い方（gh CLI 有効時）

  python3 tools/discussion_review_trigger.py --pr 42
  python3 tools/discussion_review_trigger.py --pr 42 --dry-run
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC_PATH = REPO_ROOT / "tools" / "discussion_specs" / "code_review.json"
TRIGGER_DIFF_LINES = 300
TRIGGER_LABELS = {"type:security", "type:breaking-change"}


def _get_repo() -> str:
    r = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        capture_output=True, text=True, cwd=str(REPO_ROOT),
    )
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else ""


def _gh(*args: str, repo: str = "") -> tuple[int, str]:
    repo_flag = ["-R", repo] if repo else []
    result = subprocess.run(
        ["gh", *args, *repo_flag],
        capture_output=True, text=True, cwd=str(REPO_ROOT),
    )
    return result.returncode, result.stdout.strip()


def get_pr_info_gh(pr_number: int, repo: str) -> dict:
    """gh CLI で PR 情報を取得する（ローカル環境用）。"""
    rc, out = _gh("pr", "view", str(pr_number),
                  "--json", "labels,additions,deletions,headRefName,number",
                  repo=repo)
    if rc != 0:
        return {}
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {}


def get_changed_files_gh(pr_number: int, repo: str) -> list[str]:
    """gh CLI で変更ファイル一覧を取得する（ローカル環境用）。"""
    rc, out = _gh("pr", "diff", str(pr_number), "--name-only", repo=repo)
    if rc != 0:
        return []
    return [f for f in out.splitlines() if f.strip()]


def should_trigger(diff_lines: int, labels: set[str]) -> tuple[bool, str]:
    matched = labels & TRIGGER_LABELS
    if matched:
        return True, f"ラベル {sorted(matched)} 検出"
    if diff_lines >= TRIGGER_DIFF_LINES:
        return True, f"差分 {diff_lines} 行（閾値 {TRIGGER_DIFF_LINES} 行）"
    return False, f"差分 {diff_lines} 行・対象ラベルなし（閾値未達）"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Layer 2 議論型レビュー自動トリガー（Issue #97）",
    )
    parser.add_argument("--pr", type=int, required=True, help="PR 番号")
    parser.add_argument("--dry-run", action="store_true",
                        help="判定のみ・実際にはレビューを実行しない")
    # クラウド環境用: mcp__github__pull_request_read で取得した値を直接渡す
    parser.add_argument("--diff-lines", type=int, default=None,
                        help="差分行数（追加+削除）。省略時は gh CLI で取得を試みる")
    parser.add_argument("--labels", default="",
                        help="カンマ区切りのラベル名一覧。省略時は gh CLI で取得を試みる")
    parser.add_argument("--changed-files", default="",
                        help="カンマ区切りの変更ファイルパス一覧。省略時は gh CLI で取得を試みる")
    parser.add_argument("--legacy", action="store_true",
                        help="旧経路（run_discussion_review.py = claude -p）を直接起動する（フォールバック用）")
    args = parser.parse_args()

    # 引数で直接提供された場合はそれを使う（クラウド環境）
    if args.diff_lines is not None:
        diff_lines = args.diff_lines
        labels = {la.strip() for la in args.labels.split(",") if la.strip()}
        changed_files = [f.strip() for f in args.changed_files.split(",") if f.strip()]
    else:
        # gh CLI で取得を試みる（ローカル環境）
        repo = _get_repo()
        pr_info = get_pr_info_gh(args.pr, repo)
        if not pr_info:
            print(
                f"⚠️ PR #{args.pr} の情報を取得できませんでした。\n"
                "クラウド環境では --diff-lines / --labels / --changed-files を指定してください。",
                file=sys.stderr,
            )
            sys.exit(1)
        diff_lines = pr_info.get("additions", 0) + pr_info.get("deletions", 0)
        labels = {la["name"] for la in pr_info.get("labels", [])}
        changed_files = get_changed_files_gh(args.pr, repo)

    trigger, reason = should_trigger(diff_lines, labels)
    if not trigger:
        print(f"ℹ️ Layer 2 レビュー不要: {reason}")
        sys.exit(0)

    # 実行プラン JSON（stdout）と混ざらないよう、進捗ログは stderr へ出す
    print(f"🔍 Layer 2 レビュー起動: {reason}", file=sys.stderr)

    if args.dry_run:
        print("(dry-run: 実行しません)")
        sys.exit(0)

    # 変更ファイルのうちリポジトリに存在するものだけターゲットに含める
    existing = [f for f in changed_files if (REPO_ROOT / f).exists()]
    targets = ",".join(existing) if existing else ""

    if not args.legacy:
        # ネイティブ経路（既定・Issue #193）: 実行プランを出力し、呼び出し元エージェントが
        # discussion-review スキル（ネイティブ Agent Teams）でこのプランを実行する。
        plan = {
            "action": "run_native_discussion_review",
            "skill": "discussion-review",
            "id": f"pr-{args.pr}",
            "spec": str(SPEC_PATH),
            "targets": existing,
            "rounds": 2,
            "reason": reason,
            "fallback_command": (
                f"python3 tools/discussion_review_trigger.py --pr {args.pr} "
                f"--diff-lines {diff_lines} --labels \"{','.join(sorted(labels))}\" "
                f"--changed-files \"{','.join(changed_files)}\" --legacy"
            ),
        }
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        print("▶ 上記プランに従い discussion-review スキル（ネイティブ）で Layer 2 を実行してください。",
              file=sys.stderr)
        sys.exit(0)

    # --legacy: 旧経路（claude -p 駆動）をサブプロセス起動（フォールバック）
    target_args = ["--targets", targets] if targets else []
    rc = subprocess.call(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "run_discussion_review.py"),
            "--id", f"pr-{args.pr}",
            "--spec", str(SPEC_PATH),
            *target_args,
            "--rounds", "2",
        ],
        cwd=str(REPO_ROOT),
    )

    if rc != 0:
        print(
            f"⚠️ Layer 2 レビュー失敗（exit {rc}）。"
            "Layer 1 / Layer 3 レビューで継続します。",
            file=sys.stderr,
        )
        sys.exit(rc)

    print("✅ Layer 2 レビュー完了")


if __name__ == "__main__":
    main()
