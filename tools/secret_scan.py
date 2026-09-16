#!/usr/bin/env python3
"""secret_scan.py — コミット・push 前の秘密（トークン・鍵・認証情報）検知ゲート（Issue #678）

下流リポジトリでトークン・シークレットの誤コミットが多発した根本原因は、既存の秘密防御が
すべて「Claude に読ませない」側（permissions.deny の Read・pre-tool-use-router.sh の Bash 読取
ガード）で、「git 履歴へ入れない」側のゲートが 1 つも無かったこと。自動保全コミット（`git add -A`）
→ 自律 PR → 自動マージの完全自律フローには人の目が無いため、作業ツリーに置かれた秘密は
そのまま main に到達していた。本ツールはその「入れない」側の共通実装で、以下から呼ばれる:

  - git pre-commit フック（.claude/hooks/git-pre-commit.sh・全コミット経路）
  - pre-tool-use-router.sh（Bash `git commit` のステージ済み / `mcp__github__push_files` 等の
    tool_input）・pre-git-push-check.sh（未 push 差分）
  - 自動保全コミット 3 フック（lib/secret_scan.sh の stage_all_except_secrets）
  - self_review_check.py（PR 作成前・origin/<default> との差分）

標準ライブラリのみ（クラウド実行環境に gitleaks 等は無く、導入も保証できない）。

使い方:
  python3 tools/secret_scan.py --staged            # index（GIT_INDEX_FILE を尊重）の追加行
  python3 tools/secret_scan.py --unpushed          # @{upstream}（無ければ origin/<default>、それも無ければ空ツリー＝HEAD 全体）..HEAD の追加行
  python3 tools/secret_scan.py --base origin/main  # <ref>...HEAD（merge-base 起点）の追加行
  python3 tools/secret_scan.py --paths a.py b.env  # 作業ツリーのファイル全文
  python3 tools/secret_scan.py --all               # git ls-files 全件（監査用）
  python3 tools/secret_scan.py --json < input.json # {"files":[{"path","content"}]} または {"path","content"}
  python3 tools/secret_scan.py --self-test

  共通オプション: --paths-only（検知したパスだけを 1 行 1 件で出力・自動保全フックのアンステージ用）

終了コード: 0 = 検知なし / 1 = 検知あり / 2 = 使い方・実行エラー
  exit 2 の扱いは検査点で異なる（security-posture-controls.md §1.6）: コミット時（git pre-commit・PreToolUse git commit・
  自動保全 3 フック）は fail-open（警告して通す・L-100 / CP-6）、push 時・MCP 直 push・PR 前・REST フォールバックは fail-closed（止める）

検知の 2 系統:
  1. ファイル名ルール（permissions.deny / pre-tool-use-router.sh / .gitignore の管理ブロックと整合）
  2. 内容ルール（サービス固有プレフィックス・秘密鍵ブロック・汎用 `token = "..."` 代入）
     git 系モードでは **追加行のみ** を見る（既存行の指摘で PR が毎回止まらないようにする）

抑制の 3 段（強い順）:
  - 行末（または行中）に `secret-scan:ignore`（互換: `pragma: allowlist secret` / `gitleaks:allow`）
  - config/secret_scan_allowlist.txt（1 行 1 パス glob・`#` 始まりはコメント。下流が自リポジトリの
    テストフィクスチャ等を除外する場所。ベースは配布しないので下流が作る）
  - プレースホルダ判定（`xxx…` / `<...>` / `${VAR}` / `example` / `dummy` / `changeme` 等の値は秘密と見なさない）

既知の限界（名前・正規表現ベースの設計上、意図的な回避は射程外）:
  - プレフィックスの無い高エントロピー文字列（自前発行の API キー等）は汎用代入ルールに一致する
    形（`key = "..."`）でしか検知しない
  - バイナリ・5 MiB 超のファイルは内容を見ない（ファイル名ルールだけ効く）
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

MAX_CONTENT_BYTES = 5 * 1024 * 1024
ALLOWLIST_FILE = Path("config/secret_scan_allowlist.txt")
INLINE_IGNORE_RE = re.compile(r"secret-scan:ignore|pragma:\s*allowlist\s+secret|gitleaks:allow")

# --- 1. ファイル名ルール ------------------------------------------------------------
# 文書拡張子はファイル名ルールの対象外（`credentials.md` のような手順書で止めない。内容ルールは効く）
DOC_EXTS = (".md", ".markdown", ".rst", ".adoc", ".html", ".htm")
# 秘密テンプレート（値がプレースホルダのはずのファイル）はファイル名ルールの対象外（内容ルールは効く）
TEMPLATE_SUFFIXES = (".example", ".sample", ".template", ".dist")
KEY_EXTS = (".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".ppk")
# ベース名の「語」で判定（語境界 = 先頭 or `-_.` 区切り・pre-tool-use-router.sh と同じ集合）
CRED_WORD_RE = re.compile(
    r"(^|[-_.])(git-credentials|netrc|credentials|service-accounts?|id_rsa|id_dsa|id_ecdsa|id_ed25519)([-_.][^/]*)?$"
)


def filename_rule(path: str) -> str | None:
    """パスが秘密ファイルの命名に一致すればルール ID を返す。"""
    base = path.rsplit("/", 1)[-1].lower()
    if base.endswith(".pub"):
        return None
    if base == ".env" or base.startswith(".env."):
        if base.endswith(TEMPLATE_SUFFIXES):
            return None
        return "dotenv"
    if base.endswith(TEMPLATE_SUFFIXES) or base.endswith(DOC_EXTS):
        return None
    if base.endswith(KEY_EXTS):
        return "key-file"
    if path.replace("\\", "/").endswith(".claude/settings.local.json"):
        return "settings-local"
    if CRED_WORD_RE.search(base):
        return "credential-file"
    return None


# --- 2. 内容ルール ---------------------------------------------------------------
# プレースホルダ判定は 2 段階:
#   LIGHT  = サービス固有プレフィックス付き（誤検知が少ない）ルールに適用。`ghp_xxxxxxxx` のような
#            文書上の例示だけを外す
#   STRONG = 汎用代入ルール（`token = "..."`）に適用。例示・環境変数参照・テスト値を広く外す
PLACEHOLDER_LIGHT_RE = re.compile(r"x{6,}|\*{3,}|<[^>]*>|\.\.\.|…|\$\{|\$[A-Z_]{3,}|REDACTED", re.I)
PLACEHOLDER_STRONG_RE = re.compile(
    r"x{4,}|\*{3,}|<[^>]*>|\.\.\.|…|\$\{|\$[A-Za-z_]|%\(|\{\{|\{[a-z_]+\}|"
    r"example|dummy|sample|placeholder|changeme|change[-_]me|your[-_]|redacted|"
    r"todo|fixme|test|fake|mock|invalid|secret-scan|0{6,}|1234567|abcdef|aaaaaa",
    re.I,
)
# 汎用代入ルールで「秘密の値」と見なす最低条件（英字と数字を両方含む・16 文字以上・同一文字の繰り返しでない）
GENERIC_VALUE_RE = re.compile(r"^(?=.*[A-Za-z])(?=.*[0-9])[A-Za-z0-9_\-/+=.]{16,}$")


@dataclass(frozen=True)
class Rule:
    rule_id: str
    regex: re.Pattern[str]
    placeholder: re.Pattern[str] | None  # 一致した値に対する抑制判定
    value_group: int = 0  # マスク表示・プレースホルダ判定に使う group


CONTENT_RULES: tuple[Rule, ...] = (
    Rule("private-key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----"), None),
    Rule("github-token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("github-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}\b"), PLACEHOLDER_LIGHT_RE),
    # 実トークンは xox?-<数字 10 桁以上>-… の構造を持つ（`xoxb-abc123def456` のような文書上の例示を外す）
    Rule("slack-token", re.compile(r"\bxox[abopsr]-[0-9]{8,}-[A-Za-z0-9-]{10,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("slack-app-token", re.compile(r"\bxapp-[0-9]-[A-Za-z0-9-]{10,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("slack-webhook", re.compile(r"https://hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]{20,}"), PLACEHOLDER_LIGHT_RE),
    Rule("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("aws-secret-key", re.compile(r"(?i)aws_secret_access_key\s*[:=]\s*['\"]?([A-Za-z0-9/+=]{40})\b"), PLACEHOLDER_LIGHT_RE, 1),
    Rule("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("openai-key", re.compile(r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9]{20,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("google-oauth-token", re.compile(r"\bya29\.[0-9A-Za-z_-]{30,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("stripe-key", re.compile(r"\b(?:sk|rk)_(?:live|test)_[0-9a-zA-Z]{24,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("sendgrid-key", re.compile(r"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"), PLACEHOLDER_LIGHT_RE),
    Rule("basic-auth-url", re.compile(r"\bhttps?://[^/\s:@'\"]+:([^/\s:@'\"]{8,})@[^\s/'\"]+"), PLACEHOLDER_STRONG_RE, 1),
    Rule("bearer-token", re.compile(r"(?i)\bbearer\s+([A-Za-z0-9_\-.=+/]{20,})"), PLACEHOLDER_STRONG_RE, 1),
    Rule(
        "generic-secret",
        re.compile(
            r"(?i)\b(?:api[_-]?key|api[_-]?secret|secret[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|"
            r"client[_-]?secret|private[_-]?key|password|passwd|token|secret)\b\s*[:=]\s*['\"]?([^'\"\s,;]{16,})"
        ),
        PLACEHOLDER_STRONG_RE,
        1,
    ),
)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int  # 0 = ファイル名ルール
    rule_id: str
    snippet: str  # マスク済み

    def render(self) -> str:
        where = f"{self.path}:{self.line}" if self.line else self.path
        return f"{where}: [{self.rule_id}] {self.snippet}"


def _mask(value: str, keep_prefix: int = 4) -> str:
    """検知した値をマスクする。ブロックメッセージは Claude のコンテキスト・Issue / PR の記録へ転記されうるため、
    平文を残すのは公知のサービスプレフィックス（`ghp_` / `AKIA` 等・keep_prefix 文字）だけにし、
    捕捉グループ（汎用代入・Bearer・URL 埋め込み認証の秘密本体）は 1 文字も出さない（#680 Layer 1 指摘）。"""
    if keep_prefix <= 0 or len(value) <= keep_prefix + 4:
        return f"{'*' * min(len(value), 8)}（{len(value)} 文字）"
    return f"{value[:keep_prefix]}…（{len(value)} 文字）"


def scan_line(line: str) -> list[tuple[str, str]]:
    """1 行を内容ルールで検査し (rule_id, masked_snippet) を返す。"""
    if INLINE_IGNORE_RE.search(line):
        return []
    out: list[tuple[str, str]] = []
    for rule in CONTENT_RULES:
        for m in rule.regex.finditer(line):
            value = m.group(rule.value_group) or ""
            if rule.placeholder is not None and rule.placeholder.search(value):
                continue
            if rule.rule_id == "generic-secret":
                if not GENERIC_VALUE_RE.match(value):
                    continue
                if len(set(value)) < 6:  # 同一文字の繰り返し・極端に単調な値
                    continue
            # value_group 付きルールは秘密本体そのものなのでプレフィックスも残さない
            out.append((rule.rule_id, _mask(value, keep_prefix=0) if rule.value_group else _mask(m.group(0))))
            break  # 同一行の同一ルールは 1 件で十分
    return out


def _is_binary(data: bytes) -> bool:
    return b"\x00" in data[:8192]


def scan_text(path: str, text: str, start_line: int = 1) -> list[Finding]:
    findings: list[Finding] = []
    for i, line in enumerate(text.splitlines(), start_line):
        for rule_id, snippet in scan_line(line):
            findings.append(Finding(path, i, rule_id, snippet))
    return findings


def scan_content(path: str, data: bytes) -> list[Finding]:
    if _is_binary(data) or len(data) > MAX_CONTENT_BYTES:
        return []
    return scan_text(path, data.decode("utf-8", errors="ignore"))


# --- git 連携 --------------------------------------------------------------------
def git(*args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r


DIFF_HEADER_RE = re.compile(r"^\+\+\+ (?:b/(.*)|/dev/null)$")
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def parse_added_lines(diff_text: str) -> list[tuple[str, int, str]]:
    """unified diff（-U0 推奨）から (path, new_line_no, added_line) を抽出する。"""
    out: list[tuple[str, int, str]] = []
    path: str | None = None
    lineno = 0
    in_hunk = False  # ハンク内では `+++ ` で始まる行も追加行（内容が `++ ` で始まるだけ）として扱う
    for raw in diff_text.split("\n"):
        if raw.startswith("diff --git "):
            in_hunk = False
            path = None
            continue
        if not in_hunk and raw.startswith("+++ "):
            m = DIFF_HEADER_RE.match(raw)
            path = m.group(1) if m and m.group(1) is not None else None
            continue
        if raw.startswith("@@"):
            m = HUNK_RE.match(raw)
            lineno = int(m.group(1)) if m else 0
            in_hunk = True
            continue
        if path is None:
            continue
        if raw.startswith("+"):
            out.append((path, lineno, raw[1:]))
            lineno += 1
        elif raw.startswith(" "):
            lineno += 1
        # "-" 行と "\\ No newline" は新側の行番号を進めない
    return out


def _diff_findings(diff_args: list[str]) -> list[Finding]:
    diff = git("diff", "--no-color", "--no-ext-diff", "-U0", "--diff-filter=AMRC", *diff_args)
    if diff.returncode != 0:
        raise RuntimeError(diff.stderr.strip() or "git diff failed")
    findings: list[Finding] = []
    for path, lineno, line in parse_added_lines(diff.stdout):
        for rule_id, snippet in scan_line(line):
            findings.append(Finding(path, lineno, rule_id, snippet))
    return findings


def _diff_paths(diff_args: list[str]) -> list[str]:
    r = git("diff", "--name-only", "--diff-filter=AMRC", "-z", *diff_args)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "git diff --name-only failed")
    return [p for p in r.stdout.split("\0") if p]


def scan_git_diff(diff_args: list[str]) -> list[Finding]:
    findings = [Finding(p, 0, rid, "（ファイル名ルール）") for p in _diff_paths(diff_args) if (rid := filename_rule(p))]
    findings.extend(_diff_findings(diff_args))
    return findings


def resolve_unpushed_base() -> str | None:
    up = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if up.returncode == 0 and up.stdout.strip():
        return up.stdout.strip()
    head = git("symbolic-ref", "refs/remotes/origin/HEAD")
    default = head.stdout.strip().rsplit("/", 1)[-1] if head.returncode == 0 and head.stdout.strip() else "main"
    for cand in (f"origin/{default}", "origin/main", "origin/master"):
        if git("rev-parse", "--verify", "--quiet", cand).returncode == 0:
            return cand
    # upstream も origin/<default> も無い（remote add 直後の初回 push 等）= 全コミットが未 push。
    # 空ツリーを基準にすると HEAD の全ファイルが「追加行」として検査対象になる（fail-open にしない）
    empty = git("hash-object", "-t", "tree", "/dev/null")
    return empty.stdout.strip() if empty.returncode == 0 and empty.stdout.strip() else None


# --- 許可リスト ------------------------------------------------------------------
def load_allowlist(root: Path) -> list[str]:
    f = root / ALLOWLIST_FILE
    if not f.is_file():
        return []
    globs: list[str] = []
    for line in f.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            globs.append(s)
    return globs


def apply_allowlist(findings: list[Finding], globs: list[str]) -> list[Finding]:
    if not globs:
        return findings
    return [f for f in findings if not any(fnmatch.fnmatch(f.path, g) for g in globs)]


# --- 入力モード ------------------------------------------------------------------
def scan_paths(paths: list[str]) -> list[Finding]:
    findings: list[Finding] = []
    for p in paths:
        rel = p.replace("\\", "/")
        rid = filename_rule(rel)
        if rid:
            findings.append(Finding(rel, 0, rid, "（ファイル名ルール）"))
        fp = Path(p)
        if not fp.is_file():
            continue
        try:
            if fp.stat().st_size > MAX_CONTENT_BYTES:
                continue
            findings.extend(scan_content(rel, fp.read_bytes()))
        except OSError:
            continue
    return findings


def scan_json(payload: object) -> list[Finding]:
    """MCP tool_input（push_files の files[] / create_or_update_file の path+content）を検査する。"""
    files: list[dict] = []
    if isinstance(payload, dict):
        if isinstance(payload.get("files"), list):
            files = [f for f in payload["files"] if isinstance(f, dict)]
        elif "path" in payload:
            files = [payload]
    elif isinstance(payload, list):
        files = [f for f in payload if isinstance(f, dict)]
    findings: list[Finding] = []
    for f in files:
        path = str(f.get("path") or "")
        content = f.get("content")
        rid = filename_rule(path)
        if rid:
            findings.append(Finding(path, 0, rid, "（ファイル名ルール）"))
        if isinstance(content, str):
            findings.extend(scan_text(path or "<content>", content))
    return findings


# --- 自己テスト ------------------------------------------------------------------
def _self_test() -> int:
    fails: list[str] = []

    def expect(cond: bool, desc: str) -> None:
        if not cond:
            fails.append(desc)

    # 秘密は文字列連結で組み立てる（このファイル自身がスキャンに掛からないようにするため）
    gh = "ghp_" + "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8"
    expect(scan_line(f"TOKEN={gh}") != [], "GitHub token を検知する")
    expect(scan_line("TOKEN=ghp_" + "x" * 36) == [], "ghp_xxxx… の例示は検知しない")
    expect(scan_line("aws_key = " + "AKIA" + "ABCDEFGHIJKLMNOP") != [], "AWS access key を検知する")
    expect(scan_line("key = " + "sk-ant-" + "api03-Zz9Yy8Xx7Ww6Vv5Uu4Tt3") != [], "Anthropic key を検知する")
    expect(scan_line("-----BEGIN " + "RSA PRIVATE KEY-----") != [], "秘密鍵ブロックを検知する")
    expect(scan_line("xoxb-" + "1234567890-ABCDEFGHIJKLMN") != [], "Slack bot token を検知する")
    expect(scan_line('api_key = "' + "Qm7Vt2Rk9Lp4Xz8Wn3Ha6" + '"') != [], "汎用代入（英数混在 16 文字超）を検知する")
    expect(scan_line('api_key = "${API_KEY}"') == [], "環境変数参照は検知しない")
    expect(scan_line('api_key = "your-api-key-here-000"') == [], "プレースホルダ値は検知しない")
    expect(scan_line("password = os.environ.get('PASSWORD')") == [], "コード上の参照は検知しない")
    expect(scan_line("token = \"" + "Qm7Vt2Rk9Lp4Xz8Wn3Ha6" + "\"  # secret-scan:ignore") == [], "行内 ignore で抑制できる")
    jwt = "eyJ" + "hbGciOiJIUzI1NiJ9" + ".eyJ" + "zdWIiOiIxIn0" + ".Ab12Cd34Ef56Gh78"
    expect(scan_line("Authorization: Bearer " + jwt) != [], "Bearer/JWT を検知する")
    expect(scan_line("https://user:" + "S3cretPa55word" + "@example.com/repo.git") != [], "URL 埋め込み認証を検知する")
    generic_val = "Qm7Vt2Rk9Lp4Xz8Wn3Ha6"
    masked = scan_line('api_key = "' + generic_val + '"')[0][1]
    expect(generic_val[:2] not in masked and generic_val[-2:] not in masked, "汎用代入の秘密本体はマスク出力に 1 文字も残さない")
    expect(scan_line(f"TOKEN={gh}")[0][1].startswith("ghp_") and gh[4:8] not in scan_line(f"TOKEN={gh}")[0][1],
           "プレフィックス系はプレフィックスだけ残し本体は残さない")
    expect(filename_rule(".env") == "dotenv", ".env はファイル名ルール")
    expect(filename_rule(".env.production") == "dotenv", ".env.* はファイル名ルール")
    expect(filename_rule(".env.example") is None, ".env.example は対象外")
    expect(filename_rule("secrets/gcp-service-account.json") == "credential-file", "service-account*.json を検知する")
    expect(filename_rule("id_rsa_test_tmp") == "credential-file", "id_rsa_* を検知する（#592 で main に紛れた実例）")
    expect(filename_rule("id_rsa.pub") is None, "公開鍵は対象外")
    expect(filename_rule("docs/credentials.md") is None, "文書は対象外")
    expect(filename_rule("config/credentials/README.md") is None, "ディレクトリ名一致では発火しない")
    expect(filename_rule("server.pem") == "key-file", "*.pem を検知する")
    expect(filename_rule(".claude/settings.local.json") == "settings-local", "settings.local.json を検知する")
    diff = "\n".join([
        "diff --git a/x.py b/x.py",
        "--- a/x.py",
        "+++ b/x.py",
        "@@ -0,0 +1,2 @@",
        "+ok = 1",
        "+TOKEN = '" + gh + "'",
        "diff --git a/bin.dat b/bin.dat",
        "Binary files differ",
    ])
    added = parse_added_lines(diff)
    expect([a[:2] for a in added] == [("x.py", 1), ("x.py", 2)], "diff の追加行と行番号を正しく取り出す")
    diff2 = "\n".join([
        "diff --git a/y.md b/y.md",
        "--- a/y.md",
        "+++ b/y.md",
        "@@ -0,0 +1,2 @@",
        "+++ nested = '" + gh + "'",  # 内容が `++ ` で始まる追加行（ヘッダと誤認してはならない）
        "+after = 1",
    ])
    added2 = parse_added_lines(diff2)
    expect([a[:2] for a in added2] == [("y.md", 1), ("y.md", 2)] and added2[0][2].startswith("++ nested"),
           "ハンク内の `+++ ` 始まりの行をヘッダと誤認せず追加行として扱う")
    js = scan_json({"files": [{"path": "a.txt", "content": "x=" + gh}, {"path": ".env", "content": "A=1"}]})
    expect({f.rule_id for f in js} == {"github-token", "dotenv"}, "JSON（push_files 形）を検査できる")
    js2 = scan_json({"path": "k.pem", "content": "-----BEGIN " + "EC PRIVATE KEY-----"})
    expect({f.rule_id for f in js2} == {"key-file", "private-key"}, "JSON（create_or_update_file 形）を検査できる")
    al = apply_allowlist([Finding("tests/fixtures/fake.pem", 0, "key-file", "")], ["tests/fixtures/*"])
    expect(al == [], "許可リストの glob でパスを除外できる")

    if fails:
        for f in fails:
            print(f"  FAIL: {f}", file=sys.stderr)
        print(f"[secret_scan --self-test] {len(fails)} 件失敗", file=sys.stderr)
        return 1
    print("[secret_scan --self-test] PASS")
    return 0


# --- エントリポイント ----------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="秘密（トークン・鍵・認証情報）の検知ゲート（Issue #678）")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--staged", action="store_true", help="index の追加行（GIT_INDEX_FILE を尊重）")
    mode.add_argument("--unpushed", action="store_true", help="@{upstream}（無ければ origin/<default>、それも無ければ空ツリー＝HEAD 全体）..HEAD の追加行")
    mode.add_argument("--base", metavar="REF", help="<REF>...HEAD（merge-base 起点）の追加行")
    mode.add_argument("--paths", nargs="+", metavar="PATH", help="作業ツリーのファイル全文")
    mode.add_argument("--all", action="store_true", help="git ls-files 全件")
    mode.add_argument("--json", action="store_true", help="stdin の JSON（MCP tool_input）")
    mode.add_argument("--self-test", action="store_true")
    ap.add_argument("--paths-only", action="store_true", help="検知したパスのみ出力（1 行 1 件・重複排除）")
    args = ap.parse_args(argv)

    if args.self_test:
        return _self_test()

    try:
        if args.json:
            payload = json.load(sys.stdin)
            findings = scan_json(payload)
            root = Path.cwd()
        else:
            top = git("rev-parse", "--show-toplevel")
            if top.returncode != 0:
                print("[secret_scan] git リポジトリではありません", file=sys.stderr)
                return 2
            root = Path(top.stdout.strip())
            os.chdir(root)
            if args.staged:
                findings = scan_git_diff(["--cached"])
            elif args.unpushed:
                base = resolve_unpushed_base()
                if base is None:
                    print("[secret_scan] 比較基準（upstream / origin/<default> / 空ツリー）を解決できません", file=sys.stderr)
                    return 2
                findings = scan_git_diff([f"{base}..HEAD"])
            elif args.base:
                findings = scan_git_diff([f"{args.base}...HEAD"])
            elif args.paths:
                findings = scan_paths(args.paths)
            elif args.all:
                ls = git("ls-files", "-z", check=True)
                findings = scan_paths([p for p in ls.stdout.split("\0") if p])
            else:
                ap.print_usage(sys.stderr)
                return 2
        findings = apply_allowlist(findings, load_allowlist(root))
    except (RuntimeError, OSError, ValueError) as e:
        print(f"[secret_scan] 実行エラー: {e}", file=sys.stderr)
        return 2

    if not findings:
        return 0
    if args.paths_only:
        seen: set[str] = set()
        for f in findings:
            if f.path not in seen:
                seen.add(f.path)
                print(f.path)
    else:
        for f in findings:
            print(f.render())
        print(
            "\n[secret_scan] 秘密の疑いを検知しました（誤検知なら行末に `secret-scan:ignore`、"
            "テストフィクスチャ等は config/secret_scan_allowlist.txt に glob を追記）",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
