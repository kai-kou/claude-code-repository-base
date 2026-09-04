#!/usr/bin/env python3
"""self_review_check.py（汎用ベース）

PR 作成前のセルフレビュー機械チェック。pre-pr-create-check.sh フックから呼ばれ、
Error 検出時（exit 1）に PR 作成をブロックする「Lv3 ハードコンストレイント」。

汎用ベースでは誤ブロックを避けるため保守的に、明確な事故のみを Error にする:
  - Error: マージコンフリクト痕跡（<<<<<<< / ======= / >>>>>>>）
  - Error: 巨大ファイルの新規追加（既定 5MB 超・SELF_REVIEW_MAX_MB で調整）
  - Warning: デバッグ痕跡（TODO/FIXME/console.log/print デバッグ等）※ブロックしない

プロジェクト固有のチェックは docs/rules/self-review-checklist.md に追記し、
本スクリプトに検査関数を足して拡張する。

終了コード: 0=合格 or Warning のみ / 1=Error あり（ブロック） / 2=チェッカー異常
"""
from __future__ import annotations
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

MAX_MB = float(os.environ.get("SELF_REVIEW_MAX_MB", "5"))
CONFLICT_MARKERS = ("<<<<<<< ", "=======", ">>>>>>> ")

# base-update-notes 追記リマインド（Issue #211）の検出スコープ。
# apply-to-repo.sh の同期（cp -a）はファイル削除・リネームを下流へ伝播しないため、
# 削除/リネーム（D/R）は下流に孤立ファイルを残す最高確度の「下流手動対応」シグナル。
# スコープは apply-to-repo.sh の SYNC_PATHS + docs/rules/ 全体（Warm 層含む）。
UPDATE_NOTES = "docs/base-update-notes.md"
DESTRUCTIVE_SCOPE = (
    "docs/rules/", ".claude/rules/", ".claude/hooks/", ".claude/skills/",
    ".claude/agents/", ".claude/output-styles/", ".claude/commands/",
    ".claude-plugin/", "tools/", "scripts/", "modules.yaml", ".mcp.json",
)
# 配線ファイル: 変更ステータスを問わず下流の手動判断（マージ・モジュール選択・
# フック登録）が要りやすいファイル。CLAUDE.md は PROTECT_PATHS（同期対象外）のため
# base 側の変更が下流へ自動伝播しない唯一級のファイルで、新規 Hot ルールの配線も
# ここに現れる（新規追加 A の代理シグナル）。
WIRING_FILES = ("modules.yaml", ".claude/settings.json", "CLAUDE.md")

# アップデート確認の基準点マーカー（apply-to-repo.sh が下流リポジトリに生成・Issue #205/#206）。
# コミット漏れは次回 apply-base 実行時に「初回適用」への無警告退行を招くため、
# PR 差分に含まれるかを問わず git status で直接検出する。
BASE_SYNC_STATE = ".claude/base-sync-state.json"

# CJK Markdown チェッカー（同ディレクトリの check_cjk_markdown.py）を再利用する。
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from check_cjk_markdown import process_text as _cjk_process_text
except ImportError:
    # ツール自体が無い場合のみ黙って無効化（任意機能）
    _cjk_process_text = None
except Exception as _e:  # noqa: BLE001
    # ツールはあるが壊れている → 黙殺すると再発防止が機能しないので原因を出す
    print(f"[self-review] Warning: check_cjk_markdown の読み込みに失敗（CJK 検査を無効化）: {_e}",
          file=sys.stderr)
    _cjk_process_text = None

# Python 危険パターン検出（FAIR Layer 0 強化・#56）。
try:
    from scan_dangerous_patterns import scan_text as _scan_py
except ImportError:
    # ツール自体が無い場合のみ黙って無効化（任意機能）
    _scan_py = None
except Exception as _e:  # noqa: BLE001
    # ツールはあるが壊れている（SyntaxError 等）→ 黙殺するとセキュリティ検査が静かに無効化される
    print(f"[self-review] Warning: scan_dangerous_patterns の読み込みに失敗（危険パターン検査を無効化）: {_e}",
          file=sys.stderr)
    _scan_py = None


def cjk_violation_lines(text: str) -> list[int]:
    """CJK 半角スペース違反のある行番号一覧を返す（チェッカー不在時は空）。"""
    if _cjk_process_text is None:
        return []
    try:
        _, violations = _cjk_process_text(text, fix=False)
        return [ln for ln, _ in violations]
    except Exception as e:  # noqa: BLE001
        print(f"[self-review] Warning: CJK 検査でエラー: {e}", file=sys.stderr)
        return []


def sh(args, timeout=20):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def default_branch() -> str:
    r = sh(["git", "symbolic-ref", "refs/remotes/origin/HEAD"])
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip().split("/")[-1]
    return "main"


def changed_files() -> list[str]:
    base = f"origin/{default_branch()}"
    r = sh(["git", "diff", "--name-only", f"{base}...HEAD"])
    # split() ではなく splitlines()。スペースを含むパスを 1 件として扱う
    files = r.stdout.splitlines() if r.returncode == 0 else []
    # ステージ済み・作業ツリーの変更も含める
    for extra in (["git", "diff", "--name-only"], ["git", "diff", "--cached", "--name-only"]):
        rr = sh(extra)
        if rr.returncode == 0:
            files += rr.stdout.splitlines()
    # 未追跡（git add 前の新規ファイル）も含める。git diff は untracked を出さないため、
    # これが無いと新規 .md が CJK 検査から漏れて AI レビュー指摘が再発する（#63）
    ru = sh(["git", "ls-files", "--others", "--exclude-standard"])
    if ru.returncode == 0:
        files += ru.stdout.splitlines()
    # 実在する追跡対象ファイルのみ、重複排除
    seen, out = set(), []
    for f in files:
        if f not in seen and Path(f).is_file():
            seen.add(f); out.append(f)
    return out


def update_notes_reminder(files: list[str]) -> str | None:
    """下流影響の破壊的シグナルがあるのに base-update-notes.md 追記が無ければ文言を返す。

    検出ロジック（開発リポジトリの議論記録・議題 ID: base-fork-review-211 の合意・Warning 一本）:
      - D/R（削除・リネーム）: DESTRUCTIVE_SCOPE 全域で拾う（range diff 1 本のみ）
      - 配線ファイル（WIRING_FILES）: ステータス不問の名前照合
      - .claude/rules/ への追加（新規 Hot 化 symlink）
    単純な内容修正（M）は自動同期で下流に届くため対象外（誤検知抑制の要）。
    base-update-notes.md を持たないリポジトリ（下流フォーク）ではスキップする。
    """
    if not Path(UPDATE_NOTES).is_file():
        return None
    if UPDATE_NOTES in files:
        return None
    impacted: list[str] = []
    r = sh(["git", "diff", "--name-status", f"origin/{default_branch()}...HEAD"])
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            st, old = parts[0][:1], parts[1]  # R100 → R / リネームは旧パスで判定
            if st in ("D", "R") and old.startswith(DESTRUCTIVE_SCOPE):
                impacted.append(f"{st}:{old}")
            elif st == "A" and old.startswith(".claude/rules/"):
                impacted.append(f"A:{old}")
    impacted += [f"変更:{f}" for f in files if f in WIRING_FILES]
    if not impacted:
        return None
    shown = ", ".join(impacted[:10]) + ("…" if len(impacted) > 10 else "")
    return (
        "下流影響シグナル（削除/リネーム・配線ファイル変更）を検出しましたが "
        f"{UPDATE_NOTES} に追記がありません: {shown}"
        " → 下流で手動対応（削除追従・settings/CLAUDE.md 配線・モジュール判断）が必要なら"
        "同一 PR でエントリを追記してください（不要な変更なら無視して構いません。"
        "特にファイル削除は同期が下流へ伝播しないため追記必須）"
    )


def base_sync_state_reminder() -> str | None:
    """base-sync-state.json が存在するのに未コミットならリマインドを返す（Issue #206）。

    PR 差分（changed_files）に載るとは限らない（別セッションで生成されたまま放置される
    ケースがある）ため、対象パス限定の git status で独立に検査する。
    """
    if not Path(BASE_SYNC_STATE).is_file():
        return None
    r = sh(["git", "status", "--porcelain", "--", BASE_SYNC_STATE])
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return (
        f"{BASE_SYNC_STATE}（アップデート確認の基準点マーカー）が未コミットです"
        " → コミットに含めないと次回の apply-base 実行が基準点を見失い、"
        "無警告で初回適用扱いに退行します（UPDATE NOTES の手動手順確認もスキップされます）"
    )


def rule_deletion_citation_reminder(files: list[str]) -> str | None:
    """docs/rules/*.md の削除行を検出したら PR 本文への実ケース記載をリマインドする（Issue #469）。

    削減の品質バー（token-optimization-rules.md「削減の品質バーを先に固定する」）は、ルール文書の
    削除・降格・要約に「実際に適用されたはずの直近の実ケース」1 件以上を PR 本文へ記載することを
    求める。self-review 実行時点では PR 本文がまだ存在しないため、ここでは削除行の有無だけを
    機械検出してリマインドする（記載の検証ではなく Warning 一本のリマインド）。
    """
    rule_docs = [f for f in files if f.startswith("docs/rules/") and f.endswith(".md")]
    if not rule_docs:
        return None
    base = f"origin/{default_branch()}"
    deleted_count: dict[str, int] = {}
    # コミット済み差分・ステージ済み・作業ツリーの 3 経路を合算する（changed_files() と同じ理由:
    # PR 作成前のセルフレビューは未コミットの編集が大半のため、HEAD 比較だけでは見落とす）
    for args in (
        ["git", "diff", "--numstat", f"{base}...HEAD", "--", *rule_docs],
        ["git", "diff", "--cached", "--numstat", "--", *rule_docs],
        ["git", "diff", "--numstat", "--", *rule_docs],
    ):
        r = sh(args)
        if r.returncode != 0:
            continue
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) != 3:
                continue
            _added, removed, path = parts
            if removed.isdigit():
                deleted_count[path] = max(deleted_count.get(path, 0), int(removed))
    deleted = [f"{path}(-{n})" for path, n in deleted_count.items() if n > 0]
    if not deleted:
        return None
    shown = ", ".join(deleted[:10]) + ("…" if len(deleted) > 10 else "")
    return (
        f"docs/rules/*.md の削除行を検出しました: {shown}"
        " → PR 本文に実ケース（Issue コメント / PR diff / セッションの行動記録を1件以上）を記載してください"
        "（token-optimization-rules.md「削減の品質バーを先に固定する」）"
    )


def hot_budget_reminder(files: list[str]) -> str | None:
    """Hot 層（`.claude/rules/` 実体・`token-optimization-rules.md`）変更時に予算超過を機械検証する（Issue #469）。"""
    hot_dir = Path(".claude/rules")
    hot_names = {p.name for p in hot_dir.glob("*.md")} if hot_dir.is_dir() else set()
    touches_hot = any(
        f == "docs/rules/token-optimization-rules.md" or Path(f).name in hot_names
        for f in files
    )
    if not touches_hot:
        return None
    proc = sh([sys.executable, "tools/check_hot_budget.py"], timeout=20)
    if proc.returncode == 0:
        return None
    lines = (proc.stdout or "").strip().splitlines()
    bullet_lines = [l.strip("- ").strip() for l in lines if l.strip().startswith("-")]
    # 通常は "- " 箇条書きの NG 理由行が本体。ツール異常（stdout 無し）等は stderr 全文を落とさず保持する
    detail = "; ".join(bullet_lines) or "; ".join(lines) or (proc.stderr or "").strip() or "unknown"
    return f"Hot 層予算チェック NG: {detail} → docs/rules/token-optimization-rules.md の増減ログを更新してください"


# pre-pr-create-check.sh は self_review_check.py プロセス全体を外側 timeout 60 秒で包む。
# ツール単体に近い秒数を許すと合計が外側予算を超え、timeout コマンドが exit=124 で
# プロセスごと強制終了する（フックは check_exit==1 のときしか hook_block しないため、
# 124 は「チェッカー自体の異常」扱いで PR 作成が無警告に通ってしまう）。
SELF_TEST_PER_TOOL_TIMEOUT = 15
SELF_TEST_BUDGET_SECONDS = 40

# 対象判定は基本 "--self-test" 文字列の有無で機械的に拾うが（新設ツールが自動で対象へ加わる）、
# チェッカー自身は .py に変更が無くても、監視対象の非 .py ファイル（.sh 等）が変更されたら
# 起動すべきものがある。例: tools/check_distribution_boundary.py は scripts/apply-to-repo.sh の
# SYNC_PATHS を検査するが、SYNC_PATHS だけを書き換える PR では check_distribution_boundary.py
# 自身が diff に含まれず self-test が起動しない（Issue #542 の Layer 1 セルフレビューで発覚）。
COMPANION_SELF_TESTS: dict[str, tuple[str, ...]] = {
    "scripts/apply-to-repo.sh": ("tools/check_distribution_boundary.py",),
    "scripts/publish-snapshot.sh": ("tools/check_distribution_boundary.py",),
    "scripts/bootstrap.sh": ("tools/check_distribution_boundary.py",),
}


def self_test_errors(files: list[str]) -> list[str]:
    """差分に含まれる --self-test 対応ツールを実行し、失敗を Error として返す（Issue #508）。

    対象判定はソース内の "--self-test" 文字列の有無で機械的に拾う（ハードコードの
    許可リストを持たないため、新設ツールが自動的に対象へ加わる）。差分に該当ツールが
    無ければ何も実行しない（既存 PR の所要時間を増やさない）。加えて、COMPANION_SELF_TESTS
    に登録された非 .py トリガーファイルが差分に含まれる場合は、対応する自己テストツールを
    diff への出現有無に関わらず対象に加える。

    本ファイル自身はこの docstring 内にも "--self-test" 文字列を含むため、対象判定に
    そのまま乗せると自分自身をサブプロセスとして再帰起動し無限にハングする。ファイル
    パスで自己除外する。

    対象はさらに、解決後の実パスが tools/ または scripts/ の実体配下にあるものに限定する
    （シンボリックリンク経由でリポジトリ外の任意ファイルを実行させない）。
    """
    errs: list[str] = []
    repo_root = Path(".").resolve()
    self_path = Path(__file__).resolve()
    allowed_dirs = (repo_root / "tools", repo_root / "scripts")

    def _is_allowed(path: Path) -> bool:
        for d in allowed_dirs:
            try:
                if path.is_relative_to(d):
                    return True
            except AttributeError:  # pragma: no cover - Python 3.8 互換フォールバック
                try:
                    path.relative_to(d)
                    return True
                except ValueError:
                    pass
        return False

    targets = [
        f for f in files
        if (f.startswith("tools/") or f.startswith("scripts/")) and f.endswith(".py")
        and Path(f).resolve() != self_path
        and _is_allowed(Path(f).resolve())
    ]
    for trigger, companions in COMPANION_SELF_TESTS.items():
        if trigger not in files:
            continue
        for companion in companions:
            if companion in targets:
                continue
            if _is_allowed(Path(companion).resolve()):
                targets.append(companion)

    started = time.monotonic()
    for f in targets:
        elapsed = time.monotonic() - started
        if elapsed > SELF_TEST_BUDGET_SECONDS:
            errs.append(
                f"--self-test 未実行: {f}（PR 前ゲートの実行時間予算 {SELF_TEST_BUDGET_SECONDS}秒を"
                f"超過。ローカルで `python3 {f} --self-test` を確認してから再度 PR 作成してください）"
            )
            continue
        try:
            text = Path(f).read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        if "--self-test" not in text:
            continue
        remaining = max(1, int(SELF_TEST_BUDGET_SECONDS - elapsed))
        per_call_timeout = min(SELF_TEST_PER_TOOL_TIMEOUT, remaining)
        try:
            proc = sh([sys.executable, f, "--self-test"], timeout=per_call_timeout)
        except subprocess.TimeoutExpired:
            errs.append(f"--self-test タイムアウト: {f}（{per_call_timeout}秒超）")
            continue
        except Exception as e:  # noqa: BLE001 - サブプロセス起動失敗等もフェイルオープンさせない
            errs.append(f"--self-test 実行エラー: {f}: {e}")
            continue
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()
            detail = tail[-1] if tail else "(出力なし)"
            errs.append(f"--self-test 失敗: {f}（exit={proc.returncode}）: {detail[:200]}")
    return errs


def main() -> int:
    if not Path(".git").exists() and sh(["git", "rev-parse", "--git-dir"]).returncode != 0:
        return 2

    errors: list[str] = []
    warnings: list[str] = []
    files = changed_files()

    for f in files:
        p = Path(f)
        try:
            size_mb = p.stat().st_size / (1024 * 1024)
            if size_mb > MAX_MB:
                errors.append(f"巨大ファイル: {f}（{size_mb:.1f}MB > {MAX_MB}MB）。Git LFS か別管理を検討してください。")
                continue
            # バイナリは内容スキャンしない
            raw = p.read_bytes()
            if b"\x00" in raw[:4096]:
                continue
            text = raw.decode("utf-8", errors="ignore")
        except Exception:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if any(line.startswith(m) or line == m for m in CONFLICT_MARKERS):
                errors.append(f"マージコンフリクト痕跡: {f}:{i}")
            low = line.lower()
            if "console.log(" in low or "debugger;" in low or "import pdb" in low:
                warnings.append(f"デバッグ痕跡の可能性: {f}:{i}")

        # CJK Markdown 半角スペース（CLAUDE.md「Markdown 出力ルール」）
        # 目視では見落とすため機械化（AI レビュアーの同種指摘を未然に防ぐ）
        if f.endswith((".md", ".markdown")):
            cjk_lines = cjk_violation_lines(text)
            if cjk_lines:
                shown = ", ".join(str(n) for n in cjk_lines[:8])
                ellipsis = "…" if len(cjk_lines) > 8 else ""
                warnings.append(
                    f"CJK 半角スペース違反: {f}（{len(cjk_lines)} 行: {shown}{ellipsis}）"
                    f" → python3 tools/check_cjk_markdown.py --fix {f}"
                )

        # Python 危険パターン（FAIR Layer 0 強化・#56）
        # ERROR=コマンドインジェクション/eval/pickle 等の高危険（ブロック）、WARNING=資格情報ハードコード等。
        # SELF_REVIEW_SECURITY=warn で ERROR を非ブロック化する逃げ道を用意（保守的運用）。
        if f.endswith(".py") and _scan_py is not None:
            block_security = os.environ.get("SELF_REVIEW_SECURITY", "block").lower() != "warn"
            try:
                for lineno, sev, code, msg in _scan_py(text, f):
                    entry = f"危険パターン {code}: {f}:{lineno} {msg}"
                    if sev == "ERROR" and block_security:
                        errors.append(entry)
                    else:
                        warnings.append(entry)
            except Exception as e:  # noqa: BLE001
                warnings.append(f"危険パターン検査でエラー: {f}: {e}")

    # --self-test を持つツールの自動実行（Issue #508・PR 作成前ゲート）
    # SELF_REVIEW_SELFTEST=warn で Error を非ブロック化する逃げ道を用意
    # （SELF_REVIEW_SECURITY と同じパターン。フレークな self-test 調査中の一時回避用）。
    selftest_findings = self_test_errors(files)
    if os.environ.get("SELF_REVIEW_SELFTEST", "block").lower() == "warn":
        warnings.extend(selftest_findings)
    else:
        errors.extend(selftest_findings)

    # base-update-notes 追記リマインド（Issue #211・Warning 一本。Error 化は実測後に再検討）
    note_warn = update_notes_reminder(files)
    if note_warn:
        warnings.append(note_warn)

    # base-sync-state マーカー未コミット検出（Issue #206）
    state_warn = base_sync_state_reminder()
    if state_warn:
        warnings.append(state_warn)

    # docs/rules/*.md 削除行の実ケース記載リマインド（Issue #469・削減の品質バー）
    citation_warn = rule_deletion_citation_reminder(files)
    if citation_warn:
        warnings.append(citation_warn)

    # Hot 層予算チェック（Issue #469・実測とログの乖離・再棚卸しの合図を機械判定）
    budget_warn = hot_budget_reminder(files)
    if budget_warn:
        warnings.append(budget_warn)

    # サブエージェント定義の `tools` がフィルタで全滅していないか（#367）
    # 全滅すると委譲が「空回答」になり、しかも Claude Code は削除をエラー報告しない。
    if any(f.startswith(".claude/agents/") for f in files):
        proc = sh([sys.executable, "tools/check_agent_definitions.py"], timeout=30)
        matched = False
        for line in (proc.stdout or "").splitlines():
            if line.startswith("❌"):
                errors.append(f"サブエージェント定義: {line[2:].strip()}")
                matched = True
            elif line.startswith("⚠️"):
                warnings.append(f"サブエージェント定義: {line[2:].strip()}")
                matched = True
        # 検査自体が壊れて無警告で素通りするのを防ぐ（他の補助ツールと同じ方針）
        if proc.returncode != 0 and not matched:
            detail = (proc.stderr or proc.stdout or "").strip().splitlines()
            tail = detail[-1] if detail else "(出力なし)"
            warnings.append(
                f"サブエージェント定義チェックが異常終了しました（exit={proc.returncode}）: {tail[:200]}"
            )

    # 月次コストテレメトリの feature PR 混入チェック（#106・#242 回帰検知）
    # cost_monthly は gitignore 対象で、telemetry/cost-data ブランチへのみ永続化する（#242）。
    # 回帰シグナルは 2 種（#243 レビュー）:
    #   a) ブランチのコミット済み差分に追加/変更(A/M/R/C)として現れた（WIP 除外の破れ）
    #   b) 未追跡かつ非 ignore で現れた（gitignore エントリの破れ。--flush が再生成する）
    # 追跡解除（削除差分）と、旧ブランチ上の未コミット worktree 変更では発火させない。
    tele_prefix = "content/analytics/cost_monthly/"
    if any(f.startswith(tele_prefix) for f in files):
        ns = sh(["git", "diff", "--name-status", f"origin/{default_branch()}...HEAD"]).stdout
        committed = set()
        for line in ns.splitlines():
            parts = line.split("\t")
            if parts and parts[0][:1] in "AMRC" and parts[-1].startswith(tele_prefix):
                committed.add(parts[-1])
        untracked = set(
            sh(["git", "ls-files", "--others", "--exclude-standard", "--", tele_prefix])
            .stdout.splitlines()
        )
        tele = sorted({f for f in files if f in committed or f in untracked})
        if tele:
            warnings.append(
                "月次コストテレメトリが feature 差分に混入しています（#106・#242 回帰）: "
                f"{', '.join(tele)} → gitignore と Stop hook の WIP add 除外を確認し、差分から外してください"
            )

    # ruff 補助セキュリティチェック（FAIR Layer 0 補完・#56・opt-in）
    # 既定 OFF（誤検知ノイズ回避）。SELF_REVIEW_RUFF=1 かつ ruff 在の時のみ S(=bandit) を Warning 表示。
    if os.environ.get("SELF_REVIEW_RUFF") == "1" and shutil.which("ruff"):
        py_files = [f for f in files if f.endswith(".py")]
        if py_files:
            rr = sh(["ruff", "check", "--select", "S", "--output-format", "concise", *py_files])
            for line in (rr.stdout or "").splitlines():
                s = line.strip()
                if s and ".py:" in s and not s.lower().startswith(("found", "warning:", "error:")):
                    warnings.append(f"ruff(S): {s}")

    # スプリントメタのリマインド（session-sprint-rules.md §2/§5・#45・非ブロッキング）
    # PR の Session-Id / sp:N 記載漏れを未然に防ぐ（done_sp・セッション別ベロシティ計測のため）。
    # PR 本文・ラベルはこの時点で未確定のため Error にはせず Warning に留める（PR template と二重防御）。
    if files:
        br = sh(["git", "rev-parse", "--abbrev-ref", "HEAD"])
        cur = br.stdout.strip() if br.returncode == 0 else ""
        if cur not in ("", "main", "master", "HEAD"):
            sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
            sid_hint = f"Session-Id: {sid}" if sid else "Session-Id: $CLAUDE_CODE_SESSION_ID を PR 本文へ"
            warnings.append(
                "スプリントメタを PR 本文に記載してください（session-sprint-rules.md §2/§5）: "
                f"{sid_hint} ＋ sp:N ラベル（project-mission.md 工程別標準値 + Dynamic 補正）"
            )

    if warnings:
        print("[self-review] Warning:")
        for w in warnings[:20]:
            print(f"  - {w}")
    if errors:
        print("[self-review] Error（PR 作成をブロックします）:")
        for e in errors[:20]:
            print(f"  - {e}")
        return 1
    print("[self-review] OK（Error なし）")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"[self-review] checker error: {e}", file=sys.stderr)
        sys.exit(2)
