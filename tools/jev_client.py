#!/usr/bin/env python3
"""
jev_client.py — TypeSafe Jev（System One モデル）の共通クライアント（opt-in・fail-soft）

本ベースと下流プロジェクトが Jev を「小さな意味判断」に使うための最小ラッパー。
標準ライブラリのみで動き（追加依存なし）、以下の設計原則を機械的に担保する
（判断基準・活用パターンの SSOT は `docs/jev-integration.md`）:

  1. **opt-in**: `JEV_KEY`（または `TYPESAFE_API_KEY`）が無ければ `is_enabled()` が False を返し、
     呼び出し側は Jev なしの既存動作にそのまま倒れる。`JEV_DISABLE=1` で明示的に無効化できる。
  2. **fail-soft**: ネットワーク障害・429/529・タイムアウト・不正応答では例外を投げず `None` を返す
     （`strict=True` のときだけ raise）。Jev が落ちても呼び出し側のワークフローは止まらない。
  3. **バージョン固定**: 既定モデルは `jev-1.13.0`（`JEV_MODEL` で上書き）。`jev-latest` エイリアスは
     新版が出ると判定が黙って変わるため、閾値を較正した実装では固定 ID を使う。
  4. **state は必要最小限**: 大きな state は精度を落とす（公式 jaggedness）。呼び出し側で絞る。
  5. **サーキットブレーカー**: 同一プロセス内で `JEV_MAX_CONSECUTIVE_FAILURES`（既定 3）回連続で
     失敗したら以降は即 `None` を返す（バッチ処理が不通時にタイムアウト待ちで遅くならない）。
     成功で復帰する。フォールバックの全体設計は docs/jev-integration.md §2.1。

使い方（コード）:
    from jev_client import is_enabled, system_one
    if is_enabled():
        r = system_one({"text": text}, {"is_urgent": {"type": "noul", "instructions": "..."}})
        if r:  # None なら Jev 不通。既存ロジックへフォールバックする
            p = r["answers"]["is_urgent"]["noul"]

使い方（CLI）:
    python3 tools/jev_client.py --ping        # キーの疎通確認（GET /v1/models）。値は表示しない
    python3 tools/jev_client.py --demo        # 1 リクエストのサンプル呼び出し（3 プリミティブ）
    python3 tools/jev_client.py --self-test   # ネットワーク不要のオフラインセルフテスト
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

API_BASE = "https://api.typesafe.ai/v1"
DEFAULT_MODEL = "jev-1.13.0"
DEFAULT_TIMEOUT = 8.0
PRICE_USD_PER_MTOK = 0.042  # 入力トークン課金のみ（出力は無料）。docs.typesafe.ai/models
_RETRY_STATUSES = {429, 529}
_consecutive_failures = 0   # プロセス内サーキットブレーカーの状態


_MAX_FAILURES_DEFAULT = 3


def _max_failures() -> int:
    """連続失敗の上限（1 以上）。0 以下・非数値は既定 3 に倒す（0 だと起動直後から恒久遮断になるため）。"""
    try:
        n = int(os.environ.get("JEV_MAX_CONSECUTIVE_FAILURES", "") or _MAX_FAILURES_DEFAULT)
    except (TypeError, ValueError):
        return _MAX_FAILURES_DEFAULT
    return n if n >= 1 else _MAX_FAILURES_DEFAULT


def circuit_open() -> bool:
    """連続失敗が上限に達し、以降の呼び出しを省略している状態か。"""
    return _consecutive_failures >= _max_failures()


def reset_circuit() -> None:
    global _consecutive_failures
    _consecutive_failures = 0


def api_key() -> str | None:
    """API キー（`JEV_KEY` 優先・`TYPESAFE_API_KEY` は公式 SDK 互換のフォールバック）。"""
    return os.environ.get("JEV_KEY") or os.environ.get("TYPESAFE_API_KEY") or None


def is_enabled() -> bool:
    """Jev を使ってよい状態か（キーがあり、`JEV_DISABLE` が立っていない）。"""
    if os.environ.get("JEV_DISABLE", "").strip() in {"1", "true", "yes"}:
        return False
    return bool(api_key())


def model_name() -> str:
    return os.environ.get("JEV_MODEL", "").strip() or DEFAULT_MODEL


def _request(path: str, body: dict | None, timeout: float) -> tuple[int, dict | None]:
    key = api_key()
    if not key:
        return 0, None
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        data=data,
        method="POST" if body is not None else "GET",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
        except Exception:
            payload = None
        return e.code, payload


def system_one(
    state,
    questions: dict,
    *,
    model: str | None = None,
    timeout: float = DEFAULT_TIMEOUT,
    retries: int = 1,
    strict: bool = False,
) -> dict | None:
    """`POST /v1/systemone` を 1 回呼ぶ。成功時はレスポンス dict、失敗時は None（strict なら raise）。

    Args:
        state: 文字列・dict・list（テキストのみ）。判断に必要な部分だけを渡す。
        questions: {question_id: {"type": "choice"|"noul"|"score", "instructions": ..., "criteria": ...}}
        model: 省略時は `JEV_MODEL` → `jev-1.13.0`。
        retries: 429/529 のときの再試行回数（指数バックオフ）。
    """
    global _consecutive_failures
    if not is_enabled():
        if strict:
            raise RuntimeError("Jev は無効（JEV_KEY 未設定または JEV_DISABLE=1）")
        return None
    if circuit_open() and not strict:
        _note(f"circuit open（連続 {_consecutive_failures} 回失敗）。呼び出しを省略して None を返す")
        return None

    def fail(msg: str, exc: Exception | None = None):
        global _consecutive_failures
        _consecutive_failures += 1
        if strict:
            raise exc if exc else RuntimeError(msg)
        _note(msg)
        return None

    body = {"model": model or model_name(), "state": state, "questions": questions}
    attempt = 0
    while True:
        try:
            status, payload = _request("/systemone", body, timeout)
        except Exception as e:  # URLError・timeout・JSON 不正など
            return fail(f"request failed: {type(e).__name__}: {e}", e)
        if status == 200 and isinstance(payload, dict) and "answers" in payload:
            _consecutive_failures = 0
            return payload
        if status in _RETRY_STATUSES and attempt < retries:
            attempt += 1
            time.sleep(0.5 * (2 ** attempt))
            continue
        return fail(f"HTTP {status}: {json.dumps(payload, ensure_ascii=False)[:200] if payload else '(no body)'}")


def estimate_cost_usd(response: dict | None) -> float:
    """レスポンスの usage から概算コスト（USD）を返す（入力トークンのみ課金）。"""
    if not response:
        return 0.0
    return response.get("usage", {}).get("input_tokens", 0) * PRICE_USD_PER_MTOK / 1e6


def _note(msg: str) -> None:
    if os.environ.get("JEV_VERBOSE"):
        print(f"[jev-client] {msg}", file=sys.stderr)


# ──────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────

def _ping() -> int:
    if not is_enabled():
        print("[jev-client] 無効: JEV_KEY / TYPESAFE_API_KEY が未設定（または JEV_DISABLE=1）")
        return 2
    try:
        status, payload = _request("/models", None, DEFAULT_TIMEOUT)
    except Exception as e:
        print(f"[jev-client] ✗ 接続失敗: {type(e).__name__}: {e}")
        return 1
    if status != 200:
        print(f"[jev-client] ✗ HTTP {status}（401 ならキーが無効・失効）")
        return 1
    names = ", ".join(m.get("name", "?") for m in (payload or {}).get("models", []))
    print(f"[jev-client] ✓ 認証 OK。利用可能モデル: {names} / 既定モデル: {model_name()}")
    return 0


def _demo() -> int:
    if not is_enabled():
        print("[jev-client] 無効: JEV_KEY / TYPESAFE_API_KEY が未設定（または JEV_DISABLE=1）")
        return 2
    state = {"message": "決済連携が 3 日間失敗し続けていて売上が落ちています。至急対応してください。"}
    questions = {
        "department": {"type": "choice", "instructions": "Which team should handle `message`?",
                       "criteria": {"billing": "Payment or subscription issues",
                                    "technical": "Bugs or integration problems",
                                    "sales": "Pricing or account questions"}},
        "frustration": {"type": "score", "instructions": "How frustrated the sender of `message` appears",
                        "criteria": ["Calm, just stating facts", "Frustrated but civil", "Very angry"]},
        "is_urgent": {"type": "noul", "instructions": "`message` conveys urgency or time-sensitivity"},
    }
    t0 = time.time()
    r = system_one(state, questions, strict=True)
    dt = (time.time() - t0) * 1000
    print(json.dumps(r, ensure_ascii=False, indent=2))
    print(f"[jev-client] model={r['model']} latency={dt:.0f}ms cost≈${estimate_cost_usd(r):.6f}")
    return 0


def _self_test() -> int:
    """ネットワーク不要: opt-in 判定・fail-soft・コスト概算・リトライ分岐を検証する。"""
    import contextlib
    import unittest.mock as mock

    fails: list[str] = []

    def check(name, cond):
        if not cond:
            fails.append(name)

    with mock.patch.dict(os.environ, {"JEV_KEY": "", "TYPESAFE_API_KEY": "", "JEV_DISABLE": ""}):
        check("未設定なら無効", not is_enabled())
        check("未設定時 system_one は None", system_one("x", {}) is None)
    with mock.patch.dict(os.environ, {"JEV_KEY": "k", "JEV_DISABLE": "1"}):
        check("JEV_DISABLE=1 で無効", not is_enabled())
    with mock.patch.dict(os.environ, {"JEV_KEY": "k", "JEV_DISABLE": "", "JEV_MODEL": ""}):
        check("キーがあれば有効", is_enabled())
        check("既定モデルは固定 ID", model_name() == DEFAULT_MODEL)
        ok = {"model": DEFAULT_MODEL, "answers": {"q": {"type": "noul", "noul": 0.9}},
              "usage": {"input_tokens": 1000, "output_tokens": 10}}
        with mock.patch(f"{__name__}._request", return_value=(200, ok)):
            r = system_one("x", {"q": {"type": "noul", "instructions": "?"}})
            check("200 でレスポンスを返す", r is ok)
            check("コスト概算", abs(estimate_cost_usd(r) - 1000 * PRICE_USD_PER_MTOK / 1e6) < 1e-12)
        with mock.patch(f"{__name__}._request", return_value=(401, {"error": "unauthorized"})):
            check("401 は None（fail-soft）", system_one("x", {}) is None)
            with contextlib.suppress(RuntimeError):
                system_one("x", {}, strict=True)
                check("strict で raise", False)
        calls = {"n": 0}

        def flaky(path, body, timeout):
            calls["n"] += 1
            return (529, None) if calls["n"] == 1 else (200, ok)

        with mock.patch(f"{__name__}._request", side_effect=flaky), mock.patch("time.sleep"):
            check("529 → 1 回リトライで成功", system_one("x", {}, retries=1) is ok and calls["n"] == 2)
        with mock.patch(f"{__name__}._request", side_effect=TimeoutError("t")):
            check("例外は None（fail-soft）", system_one("x", {}) is None)
        reset_circuit()
        counter = {"n": 0}

        def down(path, body, timeout):
            counter["n"] += 1
            raise TimeoutError("down")

        with mock.patch(f"{__name__}._request", side_effect=down), \
             mock.patch.dict(os.environ, {"JEV_MAX_CONSECUTIVE_FAILURES": "3"}):
            for _ in range(5):
                system_one("x", {})
            check("連続失敗 3 回で circuit open", circuit_open())
            check("open 後は API を呼ばない", counter["n"] == 3)
        with mock.patch(f"{__name__}._request", return_value=(200, ok)):
            check("open 中は None を即返す", system_one("x", {}) is None)
            reset_circuit()
            check("reset 後は成功して復帰", system_one("x", {}) is ok and not circuit_open())
        for bad in ("0", "-1", "abc", ""):
            with mock.patch.dict(os.environ, {"JEV_MAX_CONSECUTIVE_FAILURES": bad}):
                reset_circuit()
                check(f"上限 {bad!r} は既定 3 に倒れ起動直後に open しない",
                      _max_failures() == _MAX_FAILURES_DEFAULT and not circuit_open())

    for f in fails:
        print(f"FAIL: {f}")
    print(f"jev_client セルフテスト: {'PASS' if not fails else 'FAIL'}（{len(fails)} 件失敗）")
    return 0 if not fails else 1


def main() -> None:
    p = argparse.ArgumentParser(description="TypeSafe Jev 共通クライアント（opt-in・fail-soft）")
    p.add_argument("--ping", action="store_true", help="キーの疎通確認（GET /v1/models）")
    p.add_argument("--demo", action="store_true", help="サンプル 1 リクエストを実行して応答を表示")
    p.add_argument("--self-test", action="store_true", help="オフラインのセルフテスト")
    a = p.parse_args()
    if a.self_test:
        sys.exit(_self_test())
    if a.ping:
        sys.exit(_ping())
    if a.demo:
        sys.exit(_demo())
    p.print_help()


if __name__ == "__main__":
    main()
