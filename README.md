# claude-code-base

**Claude Code（特に Claude Code on the web / クラウド実行環境）で「自律運用する AI エージェント開発」を始めるための汎用ベース。**

YouTube 動画自動制作パイプライン（個人プロジェクト）で実運用・検証されたワークフロー・ルール・スキル・ハーネスから、
**ドメイン（動画制作）に依存しない汎用部分だけ** を抽出してパッケージ化したもの。
動画・音声・画像・SNS など制作特化の資産は含まない。別目的のワークフロー構築の土台として使う。

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
> （クラウドでは 403・`gh` 自体もプリインストールされない・L-114）。ローカル端末で gh が
> 使える環境なら `gh api repos/kai-kou/claude-code-repository-base/contents/scripts/apply-to-repo.sh
> -H "Accept: application/vnd.github.raw" | bash` でもよい。
>
> 詳細・オプションは [`docs/apply-to-existing-repo.md`](docs/apply-to-existing-repo.md)。
> 初回適用後は同梱の `apply-base` スキルが入るため、以降は同じ自然文で再同期が起動する。

## 設計思想

- **全部入りで配布 → プロジェクトごとに不要なものを外す（opt-out）**。`modules.yaml` でモジュール単位の有効/無効を管理する
- **Human-on-the-loop（監視型）**: ユーザーは結果を確認するだけ。Claude が判断・実装・PR・マージまで自律実行する（CP-6）
- **多層ハーネス**: ドキュメント（Lv1）→ AI セマンティック（Lv2）→ フック（Lv3）→ CI（Lv4）でルールを段階的に強制する

## 何が入っているか

| 区分 | 内容 |
|------|------|
| **ルール**（`docs/rules/`・`.claude/rules/` に常駐 symlink） | 大原則 CP-1〜6 / 確認最小化（A-1〜A-6）/ 通知トリアージ / セッション安全・圧縮・並行制御・スプリント / PR レビューフロー / 障害調査プロトコル / 教訓管理（3層）/ ハーネス昇格 / Agent Teams / トークン最適化 ほか |
| **スキル**（`.claude/skills/`・全 18 個） | 配布・同期: apply-base / base-harvest / claude-code-spec-sync ・ PR / レビュー: pr-review-watcher / self-reviewer / code-review / discussion-review ・ 運用衛生: project-manager / project-sync / workflow-health-check / waiting-user-handler / checkpoint ・ 改善ループ: retrospective / retro-try-handler / self-improvement-loop / skill-audit ・ 調査 / 生成: research-runner / skill-creator |
| **エージェント**（`.claude/agents/`） | owner（プロダクトオーナー PO ロール・`sp:*`/`priority:*` ラベル操作のみ許可）。プロジェクト固有のレビュー役・監修役を追加可能 |
| **ハーネス**（`.claude/hooks/`） | session-start / pre-tool-use-router（main 直 push ブロック・PR 前チェック・.env ブロック）/ pre-git-push-check / pre-pr-create-check / post-tool-use-validate（拡張ポイント）/ post-tool-use-failure / post-compact / stop-router（git/PR/WIP）/ subagent-stop / permission-request-auto-allow |
| **ツール**（`tools/`） | slack_notify / triage_notification / check_pending_pr_reviews / lessons_guard ほか教訓管理 / github_push_helper / generate_project_context / sprint メトリクス / CI ヘルパー / gh variables 管理（ローカル実行専用）ほか |
| **コマンド**（`.claude/commands/`） | `/next`（次のタスク自律判定）/ `/status`（現状把握） |
| **設定** | `.claude/settings.json`（権限・サンドボックス・フック登録のテンプレート） |

## 何が入っていないか（意図的に除外）

動画制作パイプライン特化の資産は除外している:
- 台本 / 音声（VOICEVOX）/ 画像（gpt-image・Gemini）/ BGM / Remotion レンダリング / サムネイル
- YouTube / Shorts / TikTok / Instagram / note / Qiita / Zenn / X・Bluesky の各パイプライン
- キャラクター設定・SNS オーガニック運用・マーケティング・テーマ発見・リサーチ自動化
- これらに紐づくルール（`audio-pipeline-rules.md`・`youtube-*.md` 等）・スキル・ツール

> これらが必要な別ドメイン版を作る場合は、本ベースを土台に該当モジュールを追加する（`skill-creator` を使う）。

## 前提

このベースを使うには、以下が必要:

- **Claude Code** — Claude.ai 経由のサブスクリプションが必要（クラウド実行環境 / ローカル CLI のどちらでも動作する）
- **Python 3.10 以上** — `tools/*.py` の実行に必要。外部依存は `PyYAML` のみ（`requirements.txt`）
- **GitHub リポジトリ** — PR 自動化・Issue 管理の土台として使う。クラウド実行では `GH_TOKEN` は未設定のままでよい（プロキシが認証を注入する）
- 任意 — Slack（完了通知用）・`context7` の API キー（MCP 経由のドキュメント取得用）

**本プロジェクトのドキュメント・ルール・スキル定義はすべて日本語で書かれている**（英語版は提供していない）。
既定の応答スタイルも日本語のため、別の言語で運用する場合は `CLAUDE.md`「応答スタイル」節と
`.claude/output-styles/` を書き換える。

動作確認は Linux / macOS。Windows はネイティブ環境では未検証（ハーネスが bash スクリプトのため WSL を推奨）。
クラウド実行環境では `gh` CLI がプリインストールされておらず、GitHub 操作は `mcp__github__*` が一次経路になる。

## 使い方（クイックスタート）

```bash
# 1. このリポジトリを新規プロジェクトの土台として取り込む（テンプレート利用 or clone）
git clone https://github.com/kai-kou/claude-code-repository-base your-project && cd your-project

# 2. プレースホルダ置換 + symlink 同期（不要モジュールがあれば modules.yaml を編集後 --prune）
bash scripts/bootstrap.sh --repo your-org/your-repo --name "Your Project" --tz Asia/Tokyo --prune

# 3. ミッションを記入
$EDITOR docs/project-mission.md

# 4. CLAUDE.md の「応答スタイル」「PR 自律化方針」を確認・調整

# 5. クラウド実行する場合: env は Claude.ai の環境設定に登録する
#    （GH_TOKEN は未設定でよい。未設定ならプロキシが GitHub 認証を注入する）
#    ※ gh variable set 経由の登録はローカル実行専用（クラウドからは 403 で読み書き不能・L-114）
```

### プレースホルダ

bootstrap が以下を置換する（手動置換も可）:

| プレースホルダ | 置換後 |
|--------------|--------|
| `__OWNER__/__REPO__` / `{{REPO_SLUG}}` | `owner/repo`（gh / tools が参照） |
| `{{PROJECT_NAME}}` | プロジェクト名 |
| `{{PROJECT_DESCRIPTION}}` | プロジェクト説明 |

> ベース配布時点では tools/hooks に `__OWNER__/__REPO__` が残っているため、bootstrap 実行前は
> リポジトリ依存ツールが動かない（テンプレートの正常な状態）。`PROJECT_REPO` 環境変数でも上書き可能。

## 既存リポジトリへ適用する（ワンコマンド）

「新規プロジェクトの土台」としてではなく、**既にある別リポジトリへルール・スキル・ハーネスだけを後付け** したい場合は、対象リポジトリのルートで以下を実行する（毎回手動で「gh で base を参照して全部適用して」と指示する必要がなくなる）:

```bash
# git だけで動く（gh は任意）。対象リポジトリの slug は git remote から自動判定
curl -fsSL https://raw.githubusercontent.com/kai-kou/claude-code-repository-base/main/scripts/apply-to-repo.sh | bash
```

- ルール（`docs/rules/` + `.claude/rules/` symlink）・スキル（`.claude/skills/`）・ハーネス（`.claude/hooks/` + `settings.json`）・ツール一式を展開し、プレースホルダを対象 slug で置換する
- `CLAUDE.md` / `docs/project-mission.md` は **プロジェクト固有のため既定では上書きせず**、ベース版を `*.base` として横に置く（`--overwrite-project` で上書き可能）
- **冪等** なので、ベース更新後に再実行すれば最新へ同期できる
- オプション（`--prune` / `--tz` / `--ref` / `--dry-run` 等）と詳細は [`docs/apply-to-existing-repo.md`](docs/apply-to-existing-repo.md) を参照

## モジュールの有効/無効

`modules.yaml` で管理する。`core-principles` と `session-safety` は `required:true`（外せない土台）。
不要なモジュール（例: `slack-notify`・`ci-helpers`）を `enabled: false` にして
`bash scripts/bootstrap.sh --repo ... --prune` を実行すると、該当する rules / hooks / skills / tools を除去する。

手動で外す場合:
- ルール: `.claude/rules/<name>.md`（symlink）を削除（実体は `docs/rules/` に残る）
- スキル: `.claude/skills/<name>/` を削除
- フック: `.claude/settings.json` の `hooks` から該当エントリを削除

## ルールの 3 層構造

- **Hot**（`.claude/rules/` 常駐 symlink・全セッション自動読み込み）: 全セッション横断で必須なクリティカル規範のみ
- **Warm**（`docs/rules/lessons/<category>.md`・タスク依存 Read）: カテゴリ別の教訓
- **Cold**（git 履歴）: 昇格済みエントリは物理削除して履歴に委ねる

`tools/lessons_guard.py` が Hot 層の行数・エントリ数上限を機械強制する。

## Plugin / MCP として使う

本ベースは clone/テンプレート利用に加え、**Claude Code Plugin** としても読み込める。

- `.claude-plugin/plugin.json`: Plugin マニフェスト（メタデータ + `skills` / `agents` のパス宣言）。スキルは `.claude/skills/`、エージェントは `.claude/agents/owner.md` を指す
- `.mcp.json`: プロジェクトスコープの MCP サーバ定義（`context7` / `github`）。環境変数は `${VAR:-default}` 展開で、未設定でも config 解析が壊れない

### MCP サーバ（`.mcp.json`）

clone 利用時はリポジトリルートの `.mcp.json` が自動でプロジェクトスコープ MCP として認識される（初回は承認プロンプトが出る）。トークンは環境変数で渡す:

```bash
export GH_TOKEN=ghp_xxx              # github MCP（既定 https://api.githubcopilot.com/mcp/）
export CONTEXT7_API_KEY=ctx_xxx      # context7（任意・未設定でも匿名で動作）
```

### Plugin インストール

ローカルマーケットプレイス経由でインストールする場合:

```bash
# このリポジトリをマーケットプレイスとして追加
claude plugin marketplace add kai-kou/claude-code-repository-base
# プラグインをインストール
claude plugin install claude-code-base
# マニフェストの妥当性チェック
claude plugin validate .
```

> **注意（フックの扱い）**: 本ベースのフック（main 直 push ブロック等）は `.claude/settings.json` に登録されており、**clone/テンプレート利用では自動で有効** になる。Plugin インストール経由でのフック配布（`hooks/hooks.json` 形式）は未対応のため、フックのガードレールが必要な場合は clone 利用を推奨する。

## 出自

本ベースは、YouTube 動画自動制作パイプラインとして実運用していた個人プロジェクト（private リポジトリ）から、
ドメインに依存しない汎用部分だけを抽出・脱ドメイン化したスナップショット。
一部のルール本文には出自プロジェクトの事例（過去の事故・教訓）が参照として残る場合がある（フレームワークの理解に有用なため保持）。

## 運用記録について

`docs/base-update-notes.md` や `content/discussions/` の一部エントリには、著者自身が運用する
下流プロジェクトへの適用記録が含まれる。これらは第三者向けの手順書ではなく、著者がベースの変更を
自分の下流プロジェクトへ同期する際の作業ログである。実運用で使われている証跡として意図的に残しているが、
本ベースを利用するうえで読む必要はない。

`content/discussions/` は議論型レビュー（敵対的相互レビュー）の記録で、設計判断の経緯を残す ADR に相当する。
`tools/discussion_whiteboard.py` の現役の参照先でもあるため、不要な場合はディレクトリごと削除してよい。

## License

[MIT](LICENSE)

ただし `.claude/skills/skill-creator/` は Anthropic 公式の Skill 作成リファレンス実装を取り込んだもので、
**Apache License 2.0**（同ディレクトリの [`LICENSE.txt`](.claude/skills/skill-creator/LICENSE.txt)）に従う。
リポジトリの他の部分（MIT）とはライセンスが異なるため、再配布時は [`NOTICE`](NOTICE) を参照すること。
