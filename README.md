# claude-code-base

**Claude Code に「毎回同じ指示」をしなくて済むようにする、自律運用の土台。**

ルール・スキル・フック・ツールを一式で導入し、実装から PR・マージまでを人間の確認を挟まず進める運用を、
安全弁つきで敷くための汎用ベース。GitHub リポジトリならドメインを問わず使える。

## このベースで何ができるようになるか

**保証レベル** の見方 — 🔒 は導入すればフック / スクリプトが機械的にそうするもの。📋 は運用ルールとして
定義され、Claude がそれに従って動くもの（詳細は「2 つの強度」）。

| 導入前によくある状態 | 導入後 | 保証 | 実現している資産 |
|---|---|---|---|
| セッションを開くたび「main に直接 push しないで」「作業ブランチを切って」と言い直している | ルール一式が `.claude/rules/` に常駐し全セッションで自動読込される。自分でルールを書き起こす必要がない | 📋 | `CLAUDE.md` / `docs/rules/` / `.claude/rules/`（symlink） |
| うっかり `main` へ push してしまう / 事故が怖くて自律実行させられない | `main` / `master` への直接 push が **物理的にブロック** される | 🔒 | `.claude/hooks/pre-git-push-check.sh` |
| `.env` や鍵ファイルを読ませてしまう事故が怖い | `.env`・秘密鍵・認証情報ファイルへのアクセスがブロックされる（`.env.example` 等のテンプレート名も含め一律ブロック）。Bash 経由はフック、Read / Write 経由は権限設定で二重に塞ぐ | 🔒 | `.claude/hooks/pre-tool-use-router.sh` / `.claude/settings.json` の `permissions.deny` |
| 実装のたび「PR 作っていいですか」と聞かれ、レビューとマージを自分で追いかけている | 実装 → セルフレビュー → PR 作成 → 指摘対応 → マージまで、確認を挟まず進める運用ルールになっている | 📋 | `docs/rules/pr-review-flow-summary.md` / `pr-review-watcher`・`code-review`・`self-reviewer` スキル |
| 未コミットのまま PR が作られて中身が空になる | 未コミット / 未 push 状態、セルフレビューの機械チェックが Error の状態では PR 作成がブロックされる | 🔒 | `.claude/hooks/pre-pr-create-check.sh` |
| 長い会話でコンテキスト圧縮が起きると作業中の変更を見失う | 圧縮の前後で未コミット変更が自動 commit & push される（**クラウド実行環境のみ**・作業ブランチ限定。ローカル CLI では発火しない） | 🔒 | `.claude/hooks/pre-compact.sh` / `post-compact.sh` |
| 「〇〇していいですか」が頻発し、監督しないと進まない | 確認を求めるのは A-1〜A-6 の 6 種と定義され、それ以外は自律実行する運用方針になっている | 📋 | `docs/rules/user-confirmation-minimization.md` |
| 「なぜこの変更をしたか」がチャット履歴に埋もれて後から追えない | 実質的な作業指示を Issue 化し、意図と完了条件をラベル付きで残す運用ルールになっている | 📋 | `docs/rules/user-instruction-issue-rules.md` / `project-manager` スキル |
| 同じセットアップを別リポジトリへ手作業でコピーしている | 対象リポジトリでワンコマンド（または自然文一つ）で導入でき、再実行するだけで最新へ同期できる | 🔒 | `scripts/apply-to-repo.sh` / `apply-base` スキル |

放置 Issue・マージされない PR・使われないブランチの整理は `project-sync` / `workflow-health-check` スキルとして
同梱しているが、**定期的に走らせるかどうかは利用者側の設定次第**（Claude Code の Scheduled Tasks 等で起動する）。
導入しただけで自動的に定期実行されるわけではない。

## クイックスタート

### A. 新規プロジェクトの土台にする

```bash
git clone https://github.com/kai-kou/claude-code-repository-base your-project && cd your-project

# プレースホルダ置換 + symlink 同期（不要モジュールがあれば modules.yaml を編集後 --prune）
bash scripts/bootstrap.sh --repo your-org/your-repo --name "Your Project" --tz Asia/Tokyo --prune

$EDITOR docs/project-mission.md   # ミッションを記入（CP-5 の実体）
$EDITOR CLAUDE.md                 # 応答スタイル・PR 自律化方針を確認・調整
```

### B. 既存リポジトリへ後付けする

対象リポジトリのルートで実行すると、ルール・スキル・ハーネス・ツールだけが展開される。

```bash
# git だけで動く（gh は任意）。対象リポジトリの slug は git remote から自動判定
curl -fsSL https://raw.githubusercontent.com/kai-kou/claude-code-repository-base/main/scripts/apply-to-repo.sh | bash
```

`CLAUDE.md` / `docs/project-mission.md` は **プロジェクト固有のため既定では上書きせず**、ベース版を `*.base` として
横に置く。**冪等** なので、ベース更新後に再実行すれば最新へ同期できる。
オプション（`--prune` / `--tz` / `--ref` / `--dry-run` / `--check-updates` 等）は
[`docs/apply-to-existing-repo.md`](docs/apply-to-existing-repo.md) を参照。

### C. プラグインとして導入する

Claude Code のプラグイン機構から導入する経路。**配布されるのはセットアップ用スキル `apply-base` と
`.mcp.json` の MCP サーバ定義（`context7` / `github`）だけ** で、ルール・フック本体はインストール後に
`apply-base` が対象リポジトリへ展開する。

```bash
claude plugin marketplace add kai-kou/claude-code-repository-base
claude plugin install claude-code-base@kai-kou-claude-base
```

インストール後、Claude に「claude-code-base を反映して」と伝えると本体が展開される。
**プラグインを入れただけでは 🔒 のガードレールも 📋 の常駐ルールも有効にならない。**
何が配れて何が配れないかは「[Plugin / MCP として使う](#plugin--mcp-として使う)」が正本。
手数を減らしたいだけなら B が早い。

## ユーザー確認が必要なのはこの 6 つ

「確認を挟まず進める」と言っても、人間の判断を残す境界がある。`docs/rules/user-confirmation-minimization.md` が
**既約境界外（A-1〜A-6）** として定義し、これ以外では確認を求めない運用方針にしている。

| # | 確認が必要なアクション | なぜ |
|---|---------------------|------|
| A-1 | `main` ブランチへの直接 push | 保護ブランチ。誤マージが不可逆（**これはフックでも物理的にブロックされる**） |
| A-2 | 取り消し困難な外部公開の即時手動実行 | 公開後に取り消せない |
| A-3 | 品質ゲートが **致命的 NG** のときの続行判断 | 誤りを世に出すリスク |
| A-4 | サーキットブレーカー（修正サイクル 2 回超）発動後の続行判断 | 無限ループ・予算浪費の防止 |
| A-5 | 新規マイルストーンの追加 | プロジェクト計画の骨格に影響 |
| A-6 | **アカウント設定・課金設定の変更**（Billing・クレジット購入・API 有効化・OAuth 再発行） | ユーザー個人アカウントの権限が物理的に必要 |

A-1 以外は運用ルールとして定義されたもので、フックが物理的に止めるわけではない。「導入すれば人間が
一切関与しなくてよくなる」ものではないことに注意する。

## 2 つの強度（機械強制と運用ルール）

このベースが提供するものは、強度の異なる 2 層でできている。README のアウトカム表の 🔒 / 📋 はこの区別を指す。

- **🔒 機械強制（Lv3）** — `.claude/hooks/*.sh` と `tools/*.py` が、Claude の判断を経ずに発火する。
  `main` 直 push ブロック・秘密ファイルアクセスブロック・PR 作成前チェック・圧縮前後の自動コミットが該当する。
  **導入すればスクリプトが必ず実行される**（ただし各スクリプトには発火条件がある。
  例えば圧縮前後の自動コミットはクラウド実行環境の作業ブランチに限定されている。
  条件はスクリプト冒頭のコメントに書いてある）。
- **📋 運用ルール（Lv1〜2）** — `CLAUDE.md` と `docs/rules/*.md` に書かれた方針で、Claude がそれを読んで従う。
  PR 自律化・確認最小化・Issue 化・マルチセッション調停が該当する。指示遵守に依存するため、
  常に同じ結果になることを保証するものではない（品質ゲートやサーキットブレーカーで停止する設計になっている）。

**主張を鵜呑みにする必要はない**: `main` 直 push が本当にブロックされるかは
[`.claude/hooks/pre-git-push-check.sh`](.claude/hooks/pre-git-push-check.sh) を読めば確認できる。
🔒 と書かれた項目はすべて、対応するスクリプトを読んで検証できる。

## 何が入っているか

読者の目的別に束ねると、以下の 4 つに整理できる。

| 目的 | 中身 |
|------|------|
| **指示を覚えておく** | 大原則 CP-1〜6・確認最小化（A-1〜A-6）・通知トリアージ・セッション安全 / 圧縮 / 並行制御 / スプリント・教訓管理（Hot / Warm / Cold の 3 層）などのルール（`docs/rules/` に実体、`.claude/rules/` に常駐 symlink）+ 圧縮前後の自動コミットフック |
| **PR を見届ける** | `pr-review-watcher` / `code-review` / `self-reviewer` / `discussion-review`（議論型レビュー）スキル + `pre-git-push-check` / `pre-pr-create-check` / `stop-router`（未コミット・未 PR 検知）フック |
| **リポジトリの衛生を保つ** | `project-manager` / `project-sync` / `workflow-health-check` / `waiting-user-handler` / `checkpoint` スキル + `retrospective` / `retro-try-handler` / `self-improvement-loop` / `skill-audit` の改善ループ + `check_pending_pr_reviews.py` ほかの `tools/` |
| **別のリポジトリへ配る** | `apply-base` / `claude-code-spec-sync` スキル + `scripts/bootstrap.sh` / `scripts/apply-to-repo.sh` / `modules.yaml` |

そのほか、サブエージェント定義（`.claude/agents/owner.md` = プロダクトオーナーロール）、
スラッシュコマンド（`/next` 次のタスク自律判定・`/status` 現状把握）、
`.claude/settings.json`（権限・サンドボックス・フック配線のテンプレート）を同梱する。

## 何が入っていないか

含まれるのは **ルール・スキル・ハーネス・ツールからなる汎用ワークフロー基盤だけ** で、
特定ドメインの制作・配信を自動化する資産は入っていない。具体的には、音声合成・画像生成・
動画レンダリング・SNS や記事プラットフォームへの投稿パイプライン、およびそれらに紐づく
ルール・スキル・ツールは含まない。**導入しても何かのコンテンツが自動生成されるわけではない。**

そうしたドメイン版を作る場合は、本ベースを土台に該当モジュールを追加する（`skill-creator` スキルを使う）。

## 前提

- **Claude Code** — Claude.ai 経由のサブスクリプションが必要（クラウド実行環境 / ローカル CLI のどちらでも動作する）
- **Python 3.10 以上** — `tools/*.py` の実行に必要。外部依存は `PyYAML` のみ（`requirements.txt`）
- **GitHub リポジトリ** — PR 自動化・Issue 管理の土台。クラウド実行では `GH_TOKEN` は未設定のままでよい（プロキシが認証を注入する）
- 任意 — Slack（完了通知用）・`context7` の API キー（MCP 経由のドキュメント取得用）

**ドキュメント・ルール・スキル定義はすべて日本語で書かれている**（英語版は提供していない）。
既定の応答スタイルも日本語のため、別の言語で運用する場合は `CLAUDE.md`「応答スタイル」節と
`.claude/output-styles/` を書き換える。

動作確認は Linux / macOS。Windows はネイティブ環境では未検証（ハーネスが bash スクリプトのため WSL を推奨）。
クラウド実行環境では `gh` CLI がプリインストールされておらず、GitHub 操作は `mcp__github__*` が一次経路になる
（README 内の `gh` を使う例はローカル実行向け）。

## 詳細ガイド

### プレースホルダ

`scripts/bootstrap.sh` が以下を置換する（手動置換も可）。

| プレースホルダ | 置換後 |
|--------------|--------|
| `__OWNER__/__REPO__` / `{{REPO_SLUG}}` | `owner/repo`（`tools/` が参照する対象リポジトリ） |
| `{{PROJECT_NAME}}` | プロジェクト名 |
| `{{PROJECT_DESCRIPTION}}` | プロジェクト説明 |

配布時点では `tools` / `hooks` に `__OWNER__/__REPO__` が残っており、bootstrap 実行前はリポジトリ依存ツールが
動かない（テンプレートの正常な状態）。`PROJECT_REPO` 環境変数でも上書きできる。

### モジュールの有効 / 無効

`modules.yaml` で管理する。`core-principles` と `session-safety` は `required:true`（外せない土台）。
不要なモジュール（例: `slack-notify`・`ci-helpers`）を `enabled: false` にして
`bash scripts/bootstrap.sh --repo ... --prune` を実行すると、該当する rules / hooks / skills / tools を除去する。

手動で外す場合は、ルールなら `.claude/rules/<name>.md`（symlink）を削除（実体は `docs/rules/` に残る）、
スキルなら `.claude/skills/<name>/` を削除、フックなら `.claude/settings.json` の `hooks` から該当エントリを削除する。

### ルールの 3 層構造

- **Hot**（`.claude/rules/` 常駐 symlink・全セッション自動読み込み）: 全セッション横断で必須なクリティカル規範のみ
- **Warm**（`docs/rules/lessons/<category>.md` ほか・タスク依存で Read）: カテゴリ別の教訓・詳細版
- **Cold**（git 履歴）: 昇格済みエントリは物理削除して履歴に委ねる

`tools/lessons_guard.py` が Hot 層の行数・エントリ数上限を機械強制する。

### アップデートの取り込み

適用済みリポジトリでは `bash apply-to-repo.sh --check-updates` で、前回適用以降の更新内容だけを確認できる。
このとき [`docs/base-update-notes.md`](docs/base-update-notes.md)（**手動対応が必要な更新だけを記録した
append-only のノート**）から、前回適用日以降のエントリが自動で抜粋表示される。通常の更新は再実行だけで同期される。

### Plugin / MCP として使う

clone / テンプレート利用に加え、**Claude Code Plugin** としても読み込める。ただし配布されるのは
**セットアップ用スキル `apply-base` と `.mcp.json` の MCP サーバ定義だけ** であることに注意する（理由は下記）。

`claude plugin details claude-code-base@kai-kou-claude-base` で実際に確認できる内訳（実測）:

```
Component inventory
  Skills (1)  apply-base
  Agents (0)
  Hooks (0)
  MCP servers (2)  context7, github
```

`.mcp.json` はプラグイン root の既定コンポーネント配置に含まれるため、**インストールすると
`context7` / `github` の MCP サーバ定義が自動で登録される**（`plugin.json` の `mcpServers` を空にしても
抑止できないことを実測で確認済み）。不要なら `/plugin` からプラグインを無効化する。
サブエージェント定義（`owner.md`）は、判断基準である `docs/rules/session-sprint-rules.md` が
プラグインでは配れず単体で機能しないため、**意図的に配布対象から外している**。

- `.claude-plugin/marketplace.json`: マーケットプレイス定義（自己参照・`source: "./"`）
- `.claude-plugin/plugin.json`: Plugin マニフェスト（メタデータ + `skills` のパス宣言）
- `.mcp.json`: プロジェクトスコープの MCP サーバ定義（`context7` / `github`）。環境変数は `${VAR:-default}` 展開で、未設定でも config 解析が壊れない

```bash
claude plugin marketplace add kai-kou/claude-code-repository-base
claude plugin install claude-code-base@kai-kou-claude-base
# インストール後、Claude に「claude-code-base を反映して」と伝えると apply-base が本体を展開する

export GH_TOKEN=ghp_xxx              # github MCP（既定 https://api.githubcopilot.com/mcp/）
export CONTEXT7_API_KEY=ctx_xxx      # context7（任意・未設定でも匿名で動作）
```

> 🔴 **プラグイン単体では 🔒 も 📋 も有効にならない**。Claude Code のプラグイン機構には次の制約があり、
> 本ベースの価値の中核は **プラグインとしては配れない**（公式仕様・実測で確認済み）:
>
> | 配れないもの | 理由 | 影響 |
> |---|---|---|
> | `CLAUDE.md` のプロジェクトコンテキスト | プラグイン root の `CLAUDE.md` は読み込まれない（公式明記） | 運用規約が届かない |
> | `.claude/rules/` の毎セッション常駐 | プラグインに rules というコンポーネント種別が無い | 📋 の常駐ルールが効かない |
> | `settings.json` の `permissions` / `sandbox` / `env` | プラグインが配れるのは `agent` と `subagentStatusLine` の 2 キーのみ | `.env`・秘密鍵のアクセスブロックが効かない |
>
> このためプラグインは **インストーラとして設計** してある。`/plugin install` 後に Claude へ
> 「claude-code-base を反映して」と伝えると `apply-base` が対象リポジトリへルール・フック・ツール一式を
> 展開し、そこで初めて 🔒 のガードレール（`main` 直 push ブロック等）と 📋 の常駐ルールが有効になる。
> ガードレールがすぐ必要なら、プラグインを経由せず「クイックスタート B」の 1 コマンドで導入するのが早い。

## エージェント向け入口

> **🤖 エージェントへ（このベースを対象リポジトリへ反映する手順）**: ユーザーから
> 「claude-code-base の内容を（このリポジトリに）反映して／適用して」等と言われたら、
> **同梱の `apply-base` スキルを起動する**（対象リポジトリに未導入なら下記の初回適用を先に行う）。
> スクリプトがベース本体を取得し、ルール・スキル・ハーネス・ツール一式を展開・
> プレースホルダ置換・symlink 同期まで冪等に行う（`CLAUDE.md` / `docs/project-mission.md` は保護）。
>
> **初回適用（対象リポジトリのルートで実行）**:
>
> ```bash
> # 一次経路: git clone（クラウド・ローカルとも動く。git は API プロキシと別系統）
> git clone --depth 1 https://github.com/kai-kou/claude-code-repository-base /tmp/ccb \
>   && bash /tmp/ccb/scripts/apply-to-repo.sh
> ```
>
> クラウドセッションで `git clone` が使えない場合は `mcp__github__get_file_contents` で
> `scripts/apply-to-repo.sh` を取得して実行する。**`gh api repos/...` は一次経路にしない**
> （クラウドでは 403・`gh` 自体もプリインストールされない）。
>
> 初回適用後は同梱の `apply-base` スキルが入るため、以降は同じ自然文で再同期が起動する。

## License

[MIT](LICENSE)

ただし `.claude/skills/skill-creator/` は Anthropic 公式の Skill 作成リファレンス実装を取り込んだもので、
**Apache License 2.0**（同ディレクトリの [`LICENSE.txt`](.claude/skills/skill-creator/LICENSE.txt)）に従う。
リポジトリの他の部分（MIT）とはライセンスが異なるため、再配布時は [`NOTICE`](NOTICE) を参照すること。
