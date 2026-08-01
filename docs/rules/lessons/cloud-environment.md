# クラウド実行環境の障害カタログ（Warm 層）

> **読むタイミング**: 下記の症状を **実際に観測したとき** だけ Read する（Hot 層には索引 1 行のみ・#324）。
> いずれも「発生時にどう回避するか」の手順であり、平時に常駐させても判断に影響しない。
> ハーネス（`gh_shim.py` の stderr ガイダンス・`post-tool-use-failure.sh`・`session-start.sh` の truncate）が
> 一次検知を担うため、常駐は不要と判定した（Hot 層再棚卸し・#324）。

| 症状 | エントリ |
|------|---------|
| `git push` だけが 403 / 413 / 502 で失敗する | L-079 |
| バックグラウンドエージェントの push 結果が不明 | L-080 |
| `tool call could not be parsed (retry also failed)` | L-101 |
| `E2BIG: argument list too long` で全 Bash が停止 | L-106 |
| `gh` が 403 を返す（`[gh-shim]` ガイダンスが出る） | L-114 |
| スコープ外リポジトリへの `git clone` / `ls-remote` が 403、`add_repo` が無い | L-117 |

---

## L-079: クラウド環境で git push が HTTP 403/413/502 で繰り返し失敗する

**症状**: `git push` だけが 403（権限）または 413/502（プロキシのサイズ制限）で失敗する
（pull/fetch/gh は動く）。クラウドのプロキシが書き込みをブロックするため。

**フォールバック順**: ① `mcp__github__push_files`（GitHub MCP）→
② `tools/github_push_helper.py`（GitHub Contents API で base64 PUT）。
ファイル単位 push なのでマージコミットは作れない点に注意。

**クロスリポ書き込み（別リポへの push）の注意（2026-06-30 実機検証）**: クラウドのプロキシは
**PAT 直叩き（埋め込みトークン git push / gh REST / urllib REST）を全拒否** し、**セッションの GitHub App 認証のみ許可** する。
別リポに書くには ① `add_repo` でそのリポをセッションスコープに追加 → ② **埋め込みトークンを使わないプレーン git push**
（プロキシが App 認証を注入）または **MCP `mcp__github__push_files`**。urllib+PAT 直叩きの自作同期スクリプトは
クラウドでは効かない。「403 = トークン権限不足」と即断せず、まず add_repo 漏れを疑う。

---

## L-080: バックグラウンドエージェントがサイレントに失敗し取りこぼす

**症状**: `run_in_background: true` で push 系タスクを委譲すると、エージェント失敗が
次セッションまで検知されない。
**対策**: push 委譲後は必ず `mcp__github__get_file_contents` / `list_commits` で結果を検証する。
push が重要ならフォアグラウンド実行する。

> 行動規範としての要点は `docs/rules/agent-team-summary.md`「バックグラウンドエージェント」節に
> 1 行で常駐済み（Hot 層の重複を解消・#324）。

---

## L-101: 「tool call could not be parsed (retry also failed)」でセッションが停止する

**パターン**: `The model's tool call could not be parsed (retry also failed).` で停止する。
大コンテキスト + 強い thinking で発生する Claude Code 側の既知事象。壊れた tool_use が履歴に残ると
自己回帰生成が模倣する（few-shot poisoning）ため、同一セッション内 retry は確定的に再失敗する。

**対策**:
```
✅ 発生時は retry せず /clear・新規セッションで回復（破損セッションは捨てる）
✅ 1ターンのツール呼び出しは8個以下に抑える
✅ 高負荷でない工程は軽量モデルに切り替える
❌ パースエラー後に同一セッションで retry を繰り返す（逆効果）
```

> 予防側（1 ターン 8 ツール以下）は `docs/rules/session-safety-rules.md` ルール 1 に常駐済み。
> 本エントリは **発生後の回復手順** を担当する。

---

## L-106: CLAUDE_ENV_FILE が resume 毎に肥大化し全 bash が E2BIG で停止する

**症状**: 長時間タスクで resume を繰り返した後、`echo hi` すら
`E2BIG: argument list too long, posix_spawn '/bin/bash'` で失敗し全 Bash ツールが停止する。
**根本原因**: SessionStart フックが env を毎回 truncate せず追記し、resume で数千行に肥大化する。

**対策**: `session-start.sh` 冒頭で `CLAUDE_ENV_FILE` を毎回 truncate する（**本ベース実装済み＝再発しない**）。
bash 停止中も MCP（GitHub 操作）・Write/Edit・コミットは `mcp__github__create_or_update_file` で代替可能。

---

## L-114: クラウドの gh 403 は「認証」ではなく「リポジトリの API attach」— gh を導入しても直らない

**症状**: クラウド実行環境（`CLAUDE_CODE_REMOTE=true`）で GitHub API 経路が 403 になる。
**可否は変動する**（06-30 #121 → 07-02 拡大 #133 → 07-13 文言変化 #227 → 07-14 repo REST が許可に転換 #254
→ **07-26 repo REST が再び 403 へ回帰 #338**）。2026-07-26 実測:

- ❌ **`gh` はそもそもプリインストールされていない**（公式仕様）。`apt install -y gh` で導入は可能だが、
  **導入しても repo スコープ REST が 403 なら何も解決しない**（＝ gh の導入を解決策として試さない）
- ✅ `gh api user`・`gh api rate_limit` は **200**（プロキシの認証注入は効いている）
- ❌ `gh api repos/{o}/{r}/...` は **403**「GitHub access is not enabled for this session.
  An org admin must connect the Claude GitHub App for this organization.」
- ❌ GraphQL は 403「only the pinned set of PR-review operations is served」
- ❌ `curl`/`urllib` 直叩きは `Authorization` 有無・`Bearer proxy-injected`・実 `GH_TOKEN` とも同一 403
- ✅ **MCP（`mcp__github__*`）と git 操作は生存**（どちらも API プロキシを通らない別系統）

**根本原因**: プロキシは GitHub API リクエストを **セッションに attach されたリポジトリに限定** する
（環境のネットワークアクセスレベルとは独立）。`access:"read"` の attach は git clone/fetch のみで
API アクセスは付かない。`add_repo(access:"push")` が公式の解決手段だが、auto mode classifier に
ブロックされることがある（07-26 実測）。

**対策（優先順）**: ① **MCP（`mcp__github__*`）を一次経路にする** ② git 操作は別系統で常時生存
（`git clone https://...`・`fetch/pull/push`）③ gh は当てにしない（シムは 403 → MCP ガイダンスの
発生器およびローカル互換として残す）。`gh auth status` は exit 0 でも失敗表示が出るため認証判定に使わない。
代替表・検証マトリクスの SSOT は `docs/rules/github-mcp-fallback-patterns.md`。
**判定基準**: 403 を見たら **`gh api user` を叩く** — 200 なら認証は正常で、原因は repo の attach 側。
「403 = トークン権限不足」「403 = gh 未導入」はいずれも誤診。`GH_TOKEN` を触っても直らない。

---

## L-117: タスク実行モードによっては `add_repo` 自体が提供されず、クロスリポ参照が git/MCP 双方で 403 になる

**症状**: GitHub Issue/PR 対応のリモートタスク実行モード（システムプロンプト冒頭に「Repository Scope」が
タスク起動元の単一リポジトリで明示される形態）では、`mcp__Claude_Code_Remote__add_repo` がツールリストに
存在しない（ToolSearch でもヒットしない）。この状態でスコープ外リポジトリへ `git ls-remote` / `git clone`
を実行すると **403** で失敗する（実機検証 2026-06-30・2026-07-01: スコープ外リポジトリへの
`git ls-remote` が一貫して 403、対してスコープ内リポジトリは成功）。`apply-base` スキル等の
クロスリポ参照を前提とするスキルが「git clone は常に通る」と想定していると、このモードでは成立しない。

**根本原因**: Anthropic は 2026-07-01 時点で、1 セッション/タスクに複数リポジトリを恒久的に紐付ける
公式機能を提供していない（`anthropics/claude-code` issue #23627 がオープンの feature request。
類似要望の #27934 は #23627 の重複としてクローズ済み）。
`add_repo` によるスコープ動的拡張は **インタラクティブな claude.ai/code Web セッション限定の機能** であり、
GitHub Issue/PR からの自動トリガー型タスクには搭載されない。

**対策**:
- クロスリポ参照（`apply-base` での他リポジトリ取得等）が必要な作業は、
  `add_repo` が使えるインタラクティブな claude.ai/code セッション（ユーザーが直接チャットで指示する
  通常のセッション）で実行する。
- GitHub Issue/PR 自動対応タスクの中で `git ls-remote`/`git clone` がスコープ外リポジトリに対し 403 を
  返したら、GH_TOKEN・ネットワーク設定の問題と誤診断してリトライを繰り返さない。直ちに
  「このタスク実行モードでは未対応。通常の claude.ai/code セッションで再実行が必要」と判定し、
  ユーザーにその旨を案内する（A-6 ではなく、Anthropic 側の機能制約として報告する）。
- 恒久的な複数リポジトリアクセスの公式機能がリリースされたら、本エントリとクロスリポ参照系スキルの
  前提を更新する（CP-2）。
