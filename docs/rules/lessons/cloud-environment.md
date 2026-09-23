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
| scheduled trigger セッションで `gh`（シム含む）が `FileNotFoundError`（command not found） になることがある | L-133 |

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
→ 07-26 repo REST が再び 403 へ回帰 #338 → **09-18 repo REST が再び 200・CCR routes 出現 #692**）。

**2026-09-18 実測**:

- ❌ **`gh` はそもそもプリインストールされていない**（公式仕様。PATH 上はシムだけ）
- ✅ `gh api user`・`gh api rate_limit` は **200**（プロキシの認証注入は効いている）
- ✅ **`repos/{o}/{r}/...` の REST は read も write も到達**（`pulls` / `issues` / `labels` /
  `milestones` / `actions/runs` が 200、存在しないリソースへの POST は 404）
- ❌ GraphQL は 403。ただし文言が変わり **CCR routes**（`/repos/{o}/{r}/pulls/{n}/ccr/...`）を案内する
  → review thread の一覧・Resolve、auto-merge、ready-for-review、draft 化はこの REST で代替できる
- ❌ search 系・非 repo REST（`users/{u}` `user/repos` `notifications`）・Actions variables/secrets は **403 のまま**
- ❌ **ref 削除だけは名指しで拒否**「Write access to this GitHub API path is not permitted through this proxy」
- ✅ **MCP（`mcp__github__*`）と git 操作は生存**（どちらも API プロキシを通らない別系統＝可否変動に強い）

> 🔴 **行動規範は不変**: 可否が 3 か月で 5 回変わっているため、**メインセッションは MCP 一次経路を維持する**。
> repo REST 直叩きに依存してよいのは MCP を呼べない層（フック・`tools/*.py`）だけで、使う直前に
> `curl -s -o /dev/null -w '%{http_code}' https://api.github.com/repos/{o}/{r}` で確認する。

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

**症状**: GitHub Issue/PR 対応のリモートタスク実行モードに加え、**4 時間ごとの scheduled trigger
（本リポジトリの R-1）セッションでも同様** に `mcp__Claude_Code_Remote__add_repo` がツールリストに
存在しない（ToolSearch でもヒットしない・実機再検証 2026-08-07・Issue #443）。`add_repo` 不在は
「GitHub Issue/PR 起動」固有の制約ではなく、**インタラクティブな claude.ai/code Web セッション以外の
自動タスク実行モード全般** に及ぶと判断する。

スコープ外リポジトリへの到達可否は **読み取りと書き込みで挙動が異なりうる**:
- **読み取り専用 `git clone`**: 2026-08-07 実機再検証では、対象が **public** リポジトリ
  （`kai-kou/claude-code-repository-base`）への `git clone` が exit 0 で成功した。一方
  2026-06-30・07-01 の実機検証ではスコープ外リポジトリへの `git ls-remote` が一貫して 403 だった
  （対象リポジトリの public/private は当時の記録に明記されておらず、今回の成功例と同一条件の
  再現とは断定できない）。**「read は public なら通る」と一般化せず、都度 `git ls-remote`/
  `git clone --depth 1` で実際に確認してから可否を判定する**（`apply-base` 等のクロスリポ参照を
  前提とするスキルが「git clone は常に通る」と決め打ちすると、この揺れを踏む）。
- **書き込み `git push`**: 2026-08-07 実機再検証では public リポジトリへの push も 403 だった
  （プロキシが明示メッセージを返す:
  `access denied by the git proxy: <owner>/<repo> is not in this session's authorized repository set,
  so the proxy will not inject a credential for it. To fix, add the repository to the session's sources.`）。
  `mcp__github__*` 等の GitHub API 系ツールも、システムプロンプトの「Repository Scope」に列挙された
  リポジトリ以外には到達できない（API 呼び出し自体が拒否される）。

**`create_session` による子セッションでも回避できない（2026-08-08 実機検証・#449）**: 親セッションから
`mcp__Claude_Code_Remote__create_session` で子セッションを起こし、そこで `add_repo` → clone → push を
試させても、`add_repo` は分類器にブロックされ `git push --dry-run` は 403 を返した。**「無人セッションが
push できないなら、push できるセッションを自分で起こせばよい」という回避策は成立しない**。
ルーティンの `session_context.sources` は配列だが、`create_trigger` / `update_trigger` のどちらも
sources を設定できないため、MCP からルーティンに 2 つ目のリポジトリを足すこともできない。

**根本原因**: Anthropic は 2026-08-07 時点で、1 セッション/タスクに複数リポジトリを恒久的に紐付ける
公式機能を提供していない（`anthropics/claude-code` issue #23627 がオープンの feature request。
類似要望の #27934 は #23627 の重複としてクローズ済み）。
`add_repo` によるスコープ動的拡張は **インタラクティブな claude.ai/code Web セッション限定の機能** であり、
GitHub Issue/PR からの自動トリガー型タスクにも scheduled trigger タスクにも搭載されない。

**対策**:
- クロスリポ参照（`apply-base` での他リポジトリ取得・`publish-sync` での公開リポジトリ push 等）が
  必要な作業は、`add_repo` が使えるインタラクティブな claude.ai/code セッション（ユーザーが直接チャットで
  指示する通常のセッション）で実行する。
- 自動タスク実行モード（GitHub Issue/PR 対応・scheduled trigger のいずれも）で `git ls-remote`/`git clone`/
  `git push` がスコープ外リポジトリに対し 403 を返したら、GH_TOKEN・ネットワーク設定の問題と誤診断して
  リトライを繰り返さない。直ちに「このタスク実行モードでは未対応。通常の claude.ai/code セッションで
  再実行が必要」と判定し、その旨を Issue に記録する（A-6 ではなく、Anthropic 側の機能制約として報告する。
  scheduled trigger の場合はユーザーが直接見ていないため、チャット案内ではなく Issue 記録が必須）。
- **public リポジトリの読み取りだけなら通ることがある** ため、「add_repo 不在 = 完全に到達不能」と即断せず、
  push を試みるコマンド（`git push --dry-run` 等）で実際に確認してから「未対応」と判定する
  （読み取り可否だけで書き込み可否を推定しない）。
- 恒久的な複数リポジトリアクセスの公式機能がリリースされたら、本エントリとクロスリポ参照系スキルの
  前提を更新する（CP-2）。

---

## L-133: scheduled trigger セッションで `CLAUDE_ENV_FILE` が未設定のとき、gh シムの PATH 注入が persist しないことがある（2026-09-14 発生・2026-09-23 対策実装 + 独立再検証・#656・#658）

**症状（2026-09-14 初回観測）**: R-1（4 時間ごとの scheduled trigger）セッションで
`check_pending_pr_reviews.py` を実行すると、`session-start.sh` が `[gh-shim] enabled` を出力した
にもかかわらず、後続の Bash 呼び出しで `gh` が **`FileNotFoundError`（command not found）** になる
（`gh api user` の 403 ではなく、シェルが `gh` というコマンド自体を見つけられない）。

**根本原因仮説（2026-09-14 実機確認・R-1 自身のセッションで検証）**:
- `session-start.sh` は `.claude/bin`（gh シム）を **フック実行中のプロセス内でのみ** `PATH` に
  `export` する。後続の Bash tool 呼び出しへ persist させる手段は `env_persist()`（`CLAUDE_ENV_FILE`
  への追記）のみで、`CLAUDE_ENV_FILE` が未設定なら `env_persist()` は無条件で no-op になる
  （`session-start.sh:46-51`）。
- 実機確認: 当時の R-1 セッションでは `CLAUDE_ENV_FILE` が **未設定**（`echo ${CLAUDE_ENV_FILE:-<unset>}` →
  `<unset>`）であり、後続の Bash 呼び出しで実際に `gh`（シムを含む）が PATH 上に見つからなかった。
- これは `docs/rules/github-mcp-fallback-patterns.md` §1.5 が前提としている
  「SessionStart フックが `.claude/bin` を PATH 先頭に注入する」が **`CLAUDE_ENV_FILE` 提供時のみ
  成立する条件付きの事実** であることを意味する。
- **L-114（gh api user は 200・repo REST が 403）とは別の障害モード**: L-114 は「gh 実体には到達できるが
  API 権限で弾かれる」ケース、本エントリは「gh 実体（シム含む）に **到達すらできない**」ケース。
  両方とも「クラウドでは gh を当てにしない」という結論は同じだが、エラーメッセージの切り分け
  （`command not found` vs `403`）を混同すると誤診断する。

**対策**:
- scheduled trigger セッションから `gh`（シム含む）に依存するスクリプト・手順を呼ぶ前提を置かない。
  `mcp__github__*` を直接の一次経路にする（`session-start.sh` の既存方針・Issue #249 と同じ結論）。
  `check_pending_pr_reviews.py` 等 gh 依存スクリプトは「失敗したらフォールバック」ではなく
  「scheduled trigger では最初から呼ばない」設計に倒す方が無駄な subprocess 起動を避けられる。
- **実装（2026-09-23・Issue #658 で対応・#656 follow-up）**: `CLAUDE_ENV_FILE` に依存しない PATH persist を
  `~/.bashrc` 先頭への source 行追記で実装した（`session-start.sh` の gh シム有効化ブロック。GitHub
  リポジトリ変数の伝搬で既に使っている手法と同型）。**検証結果**: 実環境の `~/.profile` は
  `[ "$BASH" ] && [ -f ~/.bashrc ] && . ~/.bashrc` を無条件実行するため、`.bashrc` 冒頭（非対話シェルの
  早期 return より前）に注入した PATH 設定は login シェル（`bash -l`）経由でも正しく伝搬することを
  `.profile`/`.bashrc` を複製した隔離 HOME で確認した（`env -i HOME=<tmp> PATH=... bash -lc 'echo $PATH'`
  が shim ディレクトリを含む）。ただし **この検証は通常セッションでの再現実験** であり、R-1 の
  scheduled trigger セッション自身（`claude -p` 等・本エントリの元検証と同じ起動経路）での実機再確認は
  未実施（次回 R-1 実行時に `command -v gh` で確認する）。
- **独立した再検証（同日 2026-09-23・上記実装より前の `session-start.sh` を使った別 scheduled trigger
  セッション自身で実施・1 回の観測）**: 上記の `~/.bashrc` 実装が main へ入る **前** に、別セッション
  （`CLAUDE_CODE_ENTRYPOINT=remote_trigger`）で `CLAUDE_ENV_FILE` が `<unset>` のまま `which gh` /
  `type gh` を実行したところ、いずれも `.claude/bin/gh` に解決し、`gh --version` もそのシムに到達して
  実行された（`exit 127` はシム自身が「実 gh 不在」時に意図して返す終了コード・`tools/gh_shim.py:941`・
  bash 標準の command-not-found と同じ値を模しているため、それ単体では「シムに到達した／していない」を
  区別する根拠にはならない点に注意。根拠は `which`/`type` の PATH 解決結果）。
  → 上記実装が無い状態でも `CLAUDE_ENV_FILE` 未設定で PATH 注入が persist するケースが存在し、
  「`env_persist()` のみが persist 手段」という根本原因仮説は少なくとも今回の環境では成立しなかった
  （原因は未特定・ハーネス側のセッション env 伝搬方式やセッション種別による違いの可能性があるが、
  1 回の観測のため一般化しない）。**この観測は `~/.bashrc` 実装の要否を否定するものではない**
  （persist しないケースが実在することは 2026-09-14 の観測が示す通りであり、恒久対策として実装した
  上記が正しい対応方針）。次回 R-1 実行時の実機確認では、この「実装前から persist するケースがある」
  という事実も踏まえ、効果測定は複数回の観測で判断する。
- 本エントリの実測が古くなったら（`CLAUDE_ENV_FILE` が scheduled trigger でも供給されるようになったら）
  `github-mcp-fallback-patterns.md` §1.5 と本エントリを同一 PR で更新する（CP-2）。

---

## L-126: CCR プラットフォーム側の Stop フックがプロジェクト側と同文の差し戻しを二重に届ける

**症状**: セッション終了時に「There are untracked files in the repository. Please commit and push …」が
`[~/.claude/stop-hook-git-check.sh]` と `[$CLAUDE_PROJECT_DIR/.claude/hooks/stop-router.sh]` の **2 系統** で届く
（本リポジトリ実測 2026-09-03・#543）。クラウド実行環境（CCR）は `~/.claude/launcher-settings.json` の
`hooks.Stop` に **独自の git チェック**（未コミット / 未追跡 / 未 push / 未署名コミット）を登録しており、
プロジェクト側 `stop-git-check.sh` と役割が重複する。リポジトリからは変更できない（`~/.claude/` はコンテナ側）。

**含意**:
- 差し戻しの回数・文量はプロジェクト側だけでは制御しきれない。続行ターンで完了報告を再掲しない規律
  （`completion-report-rules.md` §1.2）が二重防御として必要な理由の 1 つ。
- プロジェクト側 `stop-git-check.sh` を削除して一本化しない: 残留ファイル判別（origin/main と同一内容の検知・
  重複コミット防止）はプラットフォーム側に無い。
- `~/.claude/` には Slack 発セッション限定の `stop-hook-reply-gate.py`（`CCR_REPLY_STOP_HOOK_REASON` 設定時のみ
  登録・Opus 系で terminal ツール未呼び出しなら最大 3 回 block）もある。Web セッションでは未登録
  （`env | grep CCR_REPLY` が空）。Slack 発セッションで「返信していない」差し戻しが繰り返されたらこれを疑う。

**判定基準**: 同趣旨の差し戻しが `~/.claude/...` と `.claude/hooks/...` の両方から届いても異常ではない。
どちらか 1 回分だけ対応し、報告は 1〜3 行に留める（§1.2）。
