# claude-code-base UPDATE NOTES（下流リポジトリ向け移行ノート）

> **目的**: 下流リポジトリで「claude-code-base のアップデートを確認して適用して」と指示された際に、
> **手動手順が必要な更新** を参照するための append-only ノート（新しい順）。
> `scripts/apply-to-repo.sh` がアップデート確認時に、前回適用日以降のエントリを自動で抜粋表示する。
>
> 通常の更新（ルール・スキル・ツールの改良）は `apply-to-repo.sh` の再実行だけで自動同期されるため、
> ここには **書かない**。エントリを書くのは「下流で手動対応が必要な変更」と「下流の運用が変わる周知事項」だけ。

## 記載ルール（ベース側メンテナ向け）

- 下流リポジトリに手動対応（`CLAUDE.md` へのマージ・環境変数の追加・モジュール選択の再判断・breaking change）を
  求める変更を入れた PR では、**同一 PR で本ファイルの先頭（このセクションの直後）にエントリを追記** する
- 見出しは `## YYYY-MM-DD（Issue #N または PR #N）タイトル` 形式（**日付始まりが必須**。
  apply-to-repo.sh がこの日付で「前回適用日以降のエントリ」を機械抽出するため。
  括弧内は追跡できる番号であればよい＝実装中は Issue 番号で書き、PR 採番後の更新は任意）
- 各エントリには以下の 2 項目を書く:
  - **変更内容**: 何が変わったか（1〜3 行）
  - **下流で必要な手動手順**: 下流リポジトリの Claude（または人間）が実施すべき具体的手順。
    コマンド・対象ファイル・判断基準まで書く（「適宜対応」のような曖昧表現は禁止）
- 手動手順が不要な変更にはエントリを作らない（自動同期で完結するため）
- **ファイル削除・リネームを含む PR は追記必須**: `apply-to-repo.sh` の同期（`cp -a`）は
  ファイル削除・リネームを下流へ伝播しないため、base 側で削除したファイルは下流に
  **孤立ファイルとして残り続ける**。削除の事実と下流での手動削除手順を必ずエントリに書く
- 追記漏れは機械リマインドされる: `tools/self_review_check.py`（`pre-pr-create-check.sh` フックが
  自動実行）が、下流影響シグナル（同期対象パスの削除/リネーム・`modules.yaml` /
  `.claude/settings.json` / `CLAUDE.md` の変更・`.claude/rules/` への追加）を含む差分に
  本ファイルの更新が無い場合、PR 作成時に Warning を出す（非ブロック・Issue #211）
- エントリは必ず最初の `---` 区切りより **下** に置く（apply-to-repo.sh は `---` 以降の
  日付形式でない `## ` 見出しを「不正エントリ」として警告する）

---

## 2026-08-02（Issue #389）`audit-runner` スキルを追加（定期実行するかどうかを選んでください）

**変更内容**:

- 外部の監査プロトコル（既定は [claude-code-ultimate-guide の audit-prompt.md](https://github.com/FlorianBruniaux/claude-code-ultimate-guide/blob/main/tools/audit-prompt.md)）を
  **実行のたびに取得** して忠実に実行し、指摘を **議論型レビューで精査** → 採用分のみ Issue 化 → 実装 →
  PR → マージ → **同一版で再監査して before/after を対比** するスキル `audit-runner` を追加した。
- 監査スコアを鵜呑みにせず、指摘ごとに「真の欠陥 / 意図的な設計選択 / 著者の独自慣習の押し付け」を
  判定するのが中核。点数だけが上がる変更は採用しない設計。
- 成果物は `content/audits/<YYYY-MM-DD>/`（`protocol.md` / `before.md` / `after.md` / `diff.md`）に残る。

**下流で必要な手動手順**:

1. **手動実行のみで運用するなら、何もしなくてよい**（自然文「セットアップを監査して」または
   `/audit-runner` で起動する）。同期しただけで使える。
2. **定期実行したい場合のみ**、次のいずれかを登録する（SKILL.md「定期実行の登録」節に手順あり）:
   - Routine（クラウド）: `create_trigger` で `create_new_session_on_fire=true` の Routine を作り、
     プロンプトに「`audit-runner` スキルで監査プロトコルを実行し、議論 → 対応 → 再監査まで完遂する」と書く。
     cron は UTC 指定（JST から 9 時間引く）。**推奨頻度は月次**（1 サイクルでサブエージェント 4〜6 体分を消費する）
   - 既存ルーティンのスロットに 1 行追加して本スキルを起動する
3. 別の監査プロトコルを使いたい場合は、環境変数 `AUDIT_PROTOCOL_URL` で上書きする（1 実行 = 1 プロトコル）。
4. `content/audits/` を追跡したくないリポジトリは `.gitignore` に追加する（既定では追跡される）。

---

## 2026-08-02（Issue #383）`sandbox.enabled: true` を追加（ローカル環境でネットワーク許可リストが実際に効き始めます）

**変更内容**:

- `.claude/settings.json` の `sandbox` に **`enabled: true` を追加** した。従来は `allowedDomains` /
  `excludedCommands` を書いていたが `enabled` が無いためサンドボックス自体が起動しておらず、
  許可リストは **一切機能していなかった**（許可リスト外ドメインへ Bash から到達できることを実機確認）。
- あわせて `.git-credentials` / `.netrc` を `permissions.deny` と `pre-tool-use-router.sh` の
  両層でブロックするようにした（Issue #384）。
- `failIfUnavailable` は **意図的に追加していない**（サンドボックス不可の環境でセッション起動自体が
  失敗し、無人セッションが沈黙するため）。

**下流で必要な手動手順**:

1. `apply-to-repo.sh` の同期後、**自リポジトリの `.claude/settings.json` の `sandbox.network.allowedDomains`
   を見直す**。これまで許可リストは無効だったため、有効化によって **今まで通っていた外部通信が
   遮断される可能性がある**（ローカル実行時。`bwrap` / Seatbelt が使える環境）。
   自プロジェクトが実際に接続するドメイン（独自 API・パッケージレジストリ等）を洗い出して追加する。
2. 検証方法: ローカルで Claude Code を再起動し、Bash から許可リスト外のドメインへ
   `curl -s -o /dev/null -w "%{http_code}" https://example.com/` を実行してブロックされることを確認する。
   通ってしまう場合は `enabled` が反映されていないか、環境に `bwrap` が無い。
3. **クラウド実行環境（Claude Code on the web）では `bwrap` が存在せずサンドボックスは動作しない**
   （実機確認済み）。クラウドのみで運用しているなら手順 1・2 は不要だが、ローカル実行や下流配布を
   行うなら実施すること。詳細は `docs/rules/sandbox-rules.md`。

---

## 2026-08-01（Issue #379）ベースの配布元を公開リポジトリへ分離（apply-base の取得元が変わります）

**変更内容**:

- ベースの配布元が **公開リポジトリ `kai-kou/claude-code-repository-base`** になった。
  開発は従来どおり別リポジトリ（private）で行い、配布物だけを履歴なしのスナップショットとして公開側へ置く。
  これにより **ベースへのアクセス権がなくても `apply-base` / `apply-to-repo.sh` が使える** ようになった。
- 配布物の既定値を 2 点、安全側へ変更した（下流にもそのまま配布される）:
  - `.claude/settings.json` の `sandbox.excludedCommands` から `python3 *tools/*.py` 系の
    ワイルドカードを削除した。従来は **`tools/` 配下の任意の Python がネットワーク allowlist を
    無条件でバイパス**していた。現在は動的接続が必要な 2 本（secrets-broker 移行ツール）のみに限定。
  - `tools/check_pending_pr_reviews.py` の自動マージ判定に **著者検証**（`authorAssociation` が
    OWNER / MEMBER / COLLABORATOR）を追加した。従来はブランチ名の前方一致だけで判定しており、
    public リポジトリでは第三者の fork PR が無人マージ経路に到達しうる状態だった。
- `base-harvest` スキルは配布対象から外れた（著者専用の還流スキルのため）。

**下流で必要な手動手順**:

1. **`.claude/settings.json` の再確認**（`apply-to-repo.sh` は既存の settings.json を上書きしないため、
   下流側は自分で反映する必要がある）:
   - `sandbox.excludedCommands` に `python3 *tools/*.py` 系のワイルドカードが残っていたら削除する。
     削除後にツールが外部へ接続できなくなった場合は、**除外を戻すのではなく**
     `sandbox.network.allowedDomains` に必要な宛先を追加して解決する。
   - 判断根拠は `docs/rules/sandbox-rules.md`。
2. **`tools/check_pending_pr_reviews.py` を使っている場合**: 著者検証が入ったため、
   `authorAssociation` を取得できない経路では PR が自動処理の対象外になる（fail-closed）。
   クラウドでは `mcp__github__*` にこのフィールドが無いため、`gh` 経路または
   `list_repository_collaborators` によるフォールバックが要る（`docs/rules/github-mcp-fallback-patterns.md`）。
   自分の PR が拾われなくなった場合はここを疑うこと。
3. **`base-harvest` を使っていた場合**: 配布対象外になったため、次回の `apply-to-repo.sh` 実行後も
   既存ファイルは残るが更新されない。還流が必要なときは開発リポジトリ側のセッションで実行する。
4. **リモート URL の変更は不要**: 下流リポジトリ自体の remote は変わらない。
   変わるのは `apply-to-repo.sh` の `--base` 既定値（＝ベースの取得元）だけで、
   `apply-base` スキル経由なら自動的に新しい取得元が使われる。

## 2026-07-26（Issue #342）gh 非依存化 — ハーネス・スキル・ドキュメントを MCP メイン前提へ移行

- **変更内容**: #338 の実測（クラウドでは gh が未提供・導入しても repo REST は 403）を受け、
  **「gh が無い前提で全機能が成立する」状態** へ資産全体を移行した。gh 経路自体はローカル実行の互換として残す。
  - `session-start.sh`: **クラウドでの `apt install gh` を廃止**（毎セッションの無駄な導入を停止）。
    `GH_TOKEN` 未設定を警告しなくなり（`proxy-injected` が正常）、GitHub Variables ロードは
    クラウドでスキップする（プロキシが 403・MCP にも等価ツール無し）
  - `stop-pr-check.sh`: クラウドでは gh 試行をやめ、「⚠️ PR 確認できません（異常）」ではなく
    **「Claude が MCP で PR 存在を確認する」指示** を返すようになった（gh 不在は既定であり障害ではない）
  - `post-tool-use-failure.sh`: 403 ガイダンスから「repo スコープ REST は許可」という旧情報を削除し、
    MCP ツール一覧へ誘導する内容に是正
  - `.claude/skills/` 13 ファイル: 冒頭に「本ファイル内の `gh` はローカル実行専用。クラウドは
    `mcp__github__*`」という必読ブロックを追加。`pr-review-watcher` の返信・Resolve 手順は
    MCP（`add_reply_to_pull_request_comment` / `resolve_review_thread`）一次に書き換え
  - `.claude/commands/next.md`: レビュー待ち PR の確認をクラウドでは MCP 一次に変更
    （`check_pending_pr_reviews.py` はクラウドで必ず exit 3 になるため）
  - `README.md` / `scripts/apply-to-repo.sh` / `scripts/bootstrap.sh`: ベース取得を **git 一次**（gh はフォールバック）へ、
    env 登録案内を Claude.ai 環境設定へ変更
  - lessons L-050 / L-115: PR 存在確認・マージ検証の一次手段を MCP に是正
- **下流で必要な手動手順**:
  ① **`CLAUDE.md` の gh 節を base 版に合わせて更新する**（保護対象のため自動反映されない）。
  「クラウドは MCP 一次経路・gh は当てにしない」「403 の切り分けは `gh api user` が 200 かで判定」
  「git 操作は別プロキシで生存」の 3 点が入っているかを確認する。
  ② 自リポジトリ独自のスキル・スクリプトに `gh` 前提の手順があれば、
  `docs/rules/github-mcp-fallback-patterns.md` §2 の対応表で `mcp__github__*` へ読み替える
  （MCP に等価が無いラベル一覧/作成・マイルストーン・release 作成・variables はクラウドで実行不可と明記する）。
  ③ `session-start.sh` を base 版に追従していない下流は、**クラウドでの gh 自動インストールが残っていないか**
  確認して外す（セッション起動が数十秒遅くなるだけで効果がない）。
  ④ フック・`tools/*.py` が gh 失敗時に空リスト・0 件へサイレント縮退していないか点検する
  （正しい形は `gh_unavailable` / 専用 exit code で失敗を明示し、呼び出し元の Claude が MCP で引き取る）。

## 2026-07-26（Issue #338）クラウドの gh 可否を再実測 — repo スコープ REST が 403 へ回帰

- **変更内容**: 2026-07-14 に「許可へ転換」と記録した repo スコープ REST（`gh api repos/{o}/{r}/...`）が
  **2026-07-26 実測では 403 へ回帰** していた。あわせて **`gh` はクラウドにプリインストールされない**
  （公式仕様）ことが確定し、`apt install gh` で導入しても repo API が 403 なら実益がないことを実測で確認。
  403 の原因は認証ではなく **リポジトリが GitHub API アクセス付きでセッションに attach されていないこと**
  （`gh api user` は 200 で返る）。SSOT（`github-mcp-fallback-patterns.md`・L-114・CLAUDE.md の gh 節）を
  「MCP 一次経路 / git は別系統 / gh は当てにしない」へ是正した。gh シム・gh 依存スクリプトは
  ローカル互換と 403 検知ガイダンスのため **削除していない**（挙動変更なし）
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` の gh 節が **2026-07-14 版の三層記述
  （「シム + repo REST + MCP」「repo REST は動作する」）** になっている場合、base 版の
  「クラウドは MCP 一次経路・gh は当てにしない」へ更新する（CLAUDE.md は保護対象のため自動反映されない）。
  ② 自リポ独自のスクリプト・スキルが `gh api repos/...` の成功を前提にしている箇所があれば、
  失敗時に `gh_unavailable` を明示して MCP へ委譲する形（`tools/check_pending_pr_reviews.py` が参考実装）に直す。
  ③ 可否は今後も変動しうるため、疑わしいときは
  `curl -o /dev/null -w '%{http_code}' https://api.github.com/repos/{owner}/{repo}` の HTTP コードで再確認する

## 2026-07-24（Issue #314）モデル指定をエイリアス（opus/sonnet/haiku）既定に統一

- **変更内容**:
  モデル世代交代のたびに追随作業が発生する問題を解消するため、運用ファイルのモデル指定を
  **エイリアス（`opus` / `sonnet` / `haiku` / `fable`）既定** に統一した。ベース側では
  `.claude/settings.json` の `model` を `claude-sonnet-5` → `sonnet` に変更し、
  `agent-team.md` に「モデル指定の方針」を SSOT として新設（厳密 ID を書いてよい 3 例外・
  エイリアスが使える場所の一覧・provider 差異を記載）。`tools/discussion_specs/*.json` の
  `model` も full ID からエイリアスへ置換した（ネイティブ `discussion-review` が使う Agent ツールの
  `model` はエイリアスのみ受理するため、既存の不整合の修正も兼ねる）。

- **下流で必要な手動手順**:
  1. `.claude/settings.json` は下流の保護対象（プロジェクト固有設定）のため自動同期されない。
     下流の `.claude/settings.json` を開き、`"model": "claude-sonnet-5"` のように **厳密バージョン ID が
     書かれていれば `"sonnet"`（または用途に応じて `"opus"` / `"haiku"`）へ書き換える**。
     既に `"sonnet"` 等のエイリアスなら変更不要。
  2. 下流固有のスキル・サブエージェント定義（`.claude/skills/*/SKILL.md` ・ `.claude/agents/*.md` の
     frontmatter `model:`）に `claude-opus-4-8` のような厳密 ID が残っていないか
     `grep -rn "claude-opus-\|claude-sonnet-\|claude-haiku-" .claude/` で確認し、
     エイリアスへ置き換える（残す場合は「再現性のための意図的ピン留め」である旨をコメントで残す）。
  3. 下流独自のツールが `claude -p --model <full ID>` や Anthropic API 以外の経路でモデルを
     渡している場合も同様にエイリアス化する。**Anthropic API を直接叩くコードと料金表など ID を
     キーにする実装は full ID のまま**（エイリアス不可）。
  4. **provider 注意**: 下流が Bedrock / Google Cloud / Foundry 経由の場合、`sonnet` は旧世代に
     解決される。最新世代を使いたい場合は `ANTHROPIC_DEFAULT_SONNET_MODEL` /
     `ANTHROPIC_DEFAULT_OPUS_MODEL` で解決先を上書きする。

---

## 2026-07-21（Issue #280）組み込み /code-review を自前 code-review スキルで置き換え（Layer 1 標準実行手段）

- **変更内容**:
  組み込み `code-review` スキルが v2.1.216 で `disable-model-invocation` となり Claude の自律起動が
  不可になったため、同名 project スキル `.claude/skills/code-review/`（自前実装）で bundled を置換した
  （公式のスキルオーバーライド仕様を利用）。対話（`/code-review` 手打ち）・自律（`Skill(code-review)`）の
  両方から起動可能で、FAIR Layer 1 の標準実行手段を本スキルに統一。`modules.yaml` の `pr-review`
  モジュールに `code-review` を追加し、`ai-reviewer-strategy.md`・`pr-review-flow*.md`・
  `self-reviewer`/`pr-review-watcher`/`retro-try-handler`/`project-manager`/`claude-code-spec-sync` の
  各 SKILL.md・`pre-pr-create-check.sh`・`check_pending_pr_reviews.py`・`detect_pr_diff_type.py`・
  `CLAUDE.md` スキル表を整合修正（L-119 に恒久対策を追記）。
- **下流で必要な手動手順**:
  - 基本は `scripts/apply-to-repo.sh` の再実行で自動同期される（`.claude/skills/code-review/` が展開され、
    次セッションから `Skill(code-review)` が自律起動可能になる）。
  - 下流独自の CLAUDE.md を保護運用（`--overwrite-project` なし）しているリポジトリは、スキル表に
    `code-review` の行を手動で追記し、「Layer 1 は self-reviewer Step 2 で実行」と書いた独自記述が
    あれば「Layer 1 は自前 `code-review` スキル（`Skill(code-review)`）で実行」へ更新する。
  - 下流で `.claude/skills/code-review/SKILL.md` に `disable-model-invocation: true` を **追加しない**
    こと（追加すると自律起動が再び不能になり本置換の意味が消える）。

## 2026-07-17（Issue #264）Claude Code 仕様変更追随レーン（claude-code-spec-sync）を新設

- **変更内容**:
  Claude Code 本体のバージョンアップ（changelog/releases）を定期検知し、破壊的変更は即対応・
  新機能は検証フェーズを経て内部資産（rules/skills/hooks/settings）へ反映するレーンを追加した。
  新規: `tools/check_claude_code_updates.py`・`config/claude_code_spec_sync.yaml`・
  `docs/rules/claude-code-spec-sync.md`（Warm 層）・`.claude/skills/claude-code-spec-sync/`。
  `modules.yaml` に `claude-code-spec-sync` モジュール、`CLAUDE.md` のスキル表・タスク依存ルール一覧に
  エントリを追加。`claude-code-optimization.md` 末尾に「バージョン差分ログ」記録先セクションを新設。
- **下流で必要な手動手順**:
  - Issue 起票に使うラベルを作成する（存在しないと REST 経由の起票が失敗しうる）:
    ```bash
    gh label create "lane:claude-code-spec" --color 1d76db --description "Claude Code 仕様変更追随レーン（claude-code-spec-sync）"
    ```
  - 定期実行を配線する（いずれか）: ① 既存の定期ルーティン/スケジュールタスクのプリフライトに
    `python3 tools/check_claude_code_updates.py --create-issue` を追加（本リポジトリは
    `docs/routines.md` R-1 手順 3 が実装例）② 手動運用（`/claude-code-spec-sync`）のみで開始。
  - 初期 state を既知化してから運用を開始する（しないと初回に過去バージョン分の Issue が
    まとめて起票される）: `python3 tools/check_claude_code_updates.py --dry-run >/dev/null` を実行後、
    `--create-issue` なし実行は起票対象を既知化しない仕様のため、過去分を捨てたい場合は
    `config/claude_code_spec_state.json` を base 同梱の state（現行バージョンまで既知化済み）のまま
    使うか、CHANGELOG の現行バージョンを手動で既知化する。

## 2026-07-16（Issue #260）ディープリサーチの Gemini API 経路を全廃止（native /deep-research → claude -p → DIY の三層に統一）

- **変更内容**:
  ディープリサーチのフォールバック連鎖から Gemini Deep Research Max（旧 Step 3.5）を撤去し、
  「① ネイティブ `/deep-research`（Skill 直接呼び出し）→ ② `claude -p` サブプロセス経由の
  `/deep-research`（`run_deep_research_workflow.py`）→ ③ DIY（WebSearch/WebFetch のウェブリサーチ）」の
  三層に統一した（飼い主決定: 外部 LLM API によるディープリサーチは今後一切行わない）。
  `tools/run_deep_research_gemini.py` を **削除**。`run_deep_research.py` は DIY 専用ランナー化
  （`--engine gemini` は受け付けない・`--fallback-reason` で発動記録を追記可能）。
  `research-runner` SKILL.md / reference.md・`modules.yaml`・`native_capabilities.json`・
  `research_schema.json`（engine enum から `gemini-deep-research-max` を除去）・
  `research-rules.md`・`dynamic-workflows-rules.md` を同方針に更新。
- **下流で必要な手動手順**:
  - `apply-to-repo.sh` の同期（`cp -a`）は **ファイル削除を下流へ伝播しない** ため、適用済み下流では
    再適用後に以下を実行して旧 Gemini エンジンを削除する:
    ```bash
    git rm tools/run_deep_research_gemini.py
    ```
  - 下流のスケジュールタスク・スキル・ドキュメントで `run_deep_research.py {ID} --engine gemini` を
    呼んでいる箇所があれば、`run_deep_research_workflow.py {ID}`（claude -p 経由の `/deep-research`）
    または DIY（`--engine diy` 相当＝引数なし）へ書き換える。
  - ディープリサーチ用途で `GEMINI_API_KEY` を環境変数供給していた下流は、その供給設定を撤去してよい
    （画像生成 MCP 等ディープリサーチ以外の用途で使っている場合は残す）。
  - 過去の生成物 `content/research/*_deep_research.json` に `engine=gemini-deep-research-max` が
    残っていても再検証・削除は不要（スキーマ enum は新規生成物にのみ適用される）。

## 2026-07-14（Issue #252）Intent Gate ルール新設（fable-method 反映・挙動変更前の spec/test/code 権威解決）

- **変更内容**:
  外部の [The Fable Method](https://github.com/Sahir619/fable-method)（MIT）を精査し、既存資産で埋まらない
  唯一の高価値要素「Intent Gate」を反映。`docs/rules/intent-gate-rules.md`（Warm 層）を新設し、
  挙動を変える編集の前に `INTENT: code does X / check expects Y / spec says Z` を確認して不一致を surface
  する規律と、権威順（ユーザー明示 > 仕様 > テスト > 現行コード）を SSOT 化した。
  `self-review-checklist.md` §0 に目視行を 1 行追加、`CLAUDE.md`（必読ルール タスク依存リスト +
  「やってはいけないこと」）へ参照を追記。L-113（confabulation）の姉妹則で、重複定義はしていない。
- **下流で必要な手動手順**:
  - `docs/rules/intent-gate-rules.md`・`self-review-checklist.md` は `apply-to-repo.sh` の再実行で自動同期される（手動不要）。
  - **`CLAUDE.md` は下流各リポジトリが独自管理するため自動同期されない**。Intent Gate をベース同等に効かせたい
    場合のみ、下流の `CLAUDE.md`「やってはいけないこと」へ「仕様と矛盾するテストを通すために正しいコードを
    黙って書き換えない（Intent Gate・権威順 ユーザー明示 > 仕様 > テスト > 現行コード・`docs/rules/intent-gate-rules.md`）」の
    1 行と、必読ルール（タスク依存）一覧へ `intent-gate-rules.md` の 1 行を手動でマージする（不要なら無視可）。

## 2026-07-14（Issue #242）コストテレメトリ永続化を telemetry/cost-data データブランチ直 push に変更（PR レーン廃止・cost_monthly の gitignore 化）

- **変更内容**:
  `content/analytics/cost_monthly/` を main で追跡しない方式に変更（gitignore 化）。永続化は
  `tools/commit_cost_telemetry.py` がテレメトリ専用データブランチ `telemetry/cost-data` へ
  1 日 1 回 plain git push で行う（gh 非依存・クラウドの 403 制約を受けない）。
  `chore/cost-telemetry-*` の専用 PR は廃止。Stop hook（`stop-git-check.sh` /
  `pre-pr-create-check.sh`）は同パスを未コミット検知から除外する。
- **下流で必要な手動手順**:
  ① `.gitignore` の `!content/analytics/cost_monthly/` 行（否定エントリ）が残っていれば削除する
  （apply-to-repo.sh は `.gitignore` を同期しないため手動。ベース側の新 `.gitignore` コメント参照）。
  ② main で cost_monthly が追跡されている場合は追跡解除して PR でマージする:
  `git rm -r --cached content/analytics/cost_monthly/ && git commit -m "chore: cost_monthly を追跡解除（base #242 追随）"`。
  ③ 過去データの移行は不要（新 `commit_cost_telemetry.py` が初回 push 時に origin/main の
  最終追跡版・履歴上の最終版を自動で種データにマージする）。
  ④ 参照方法の変更を周知: 月次コストは `git show origin/telemetry/cost-data:content/analytics/cost_monthly/YYYY-MM.json` で確認する。

## 2026-07-14（Issue #238）再同期レビュー由来のベース改善 3 点（project 引き継ぎ・自己参照 spec 隔離・auto-allow の settings 除外）

- **変更内容**:
  ① `scripts/merge_modules_yaml.py` が再適用時に `modules.yaml` の `project:` セクション
  （`name` / `repo` / `timezone`）の下流固有値も引き継ぐようになった（従来は `enabled:false` のみ）。
  再適用のたびに `project.name` が repo slug へ巻き戻る drift が解消される（自動同期で完結）。
  ② ベース自己参照専用の議論スペック `tools/discussion_specs/public_readiness_audit.json`
  （`/home/user/claude-code-base` 前提で下流実行不能）を `docs/discussion_specs_base_only/` へ隔離し、
  `modules.yaml` の `agent-teams` モジュール `tools:` 列挙からも除外した（下流へ配布されなくなる）。
  ③ `.claude/hooks/permission-request-auto-allow.sh` が `.claude/settings.json` /
  `.claude/settings.local.json` を auto-allow の対象から除外し、通常の権限フロー（ユーザー確認）に
  委ねるようになった（権限・フック配線 SSOT の自己書き換え面を塞ぐ・自動同期で完結）。
- **下流で必要な手動手順**: ②のみ手動対応が必要。`apply-to-repo.sh` の同期（`cp -a`）は
  **ファイル削除を下流へ伝播しない** ため、過去に本ベースを適用済みの下流には
  `tools/discussion_specs/public_readiness_audit.json` が孤立ファイルとして残り続ける。
  下流リポジトリで以下を実行して削除する（ベース自己参照専用のため下流では元々実行不能な spec）:
  ```bash
  git rm tools/discussion_specs/public_readiness_audit.json
  ```
  ①③は再適用のみで完結（手動対応不要）。①適用後は下流 `modules.yaml` の `project:` 値が
  再適用で保持されるため、下流側で `project.name` を手修正する運用は不要になる。

## 2026-07-13（Issue #227）クラウドで生存する gh コマンドの記述更新（gh auth status を認証判定に使わない）

- **変更内容**: 2026-07-13 実機再検証で、`gh auth status` が exit 0 のまま stderr に「GH_TOKEN invalid」
  失敗表示を出すことを確認。ベースの `CLAUDE.md`「gh CLI / GitHub 操作」節の「クラウドで生存するのは」行から
  `gh auth status` を外した（SSOT の `github-mcp-fallback-patterns.md`・`lessons-core.md` L-114 は自動同期）。
- **下流で必要な手動手順**: 下流リポジトリの `CLAUDE.md`（保護ファイル・自動同期されない）に同じ
  「クラウドで生存するのは: `gh api user` / `gh api rate_limit` / `gh auth status` …」行がある場合、
  ベースと同様に `gh auth status` を外し「（`gh auth status` は exit 0 でも失敗表示・認証判定に使わない）」を
  追記する。該当行が無ければ対応不要。

## 2026-07-12（Issue #211）orchestrator-directive 注入本文のオーバーライド機構ほか周知 3 点

- **変更内容**: ① `orchestrator-directive.sh` の注入本文を `.claude/orchestrator-directive.txt` で
  全文差し替え可能にした（ファイル不在時は従来の既定文言・4KB 上限）。② `pre-pr-create-check.sh` の
  Layer 1 リマインダーと self_review_check の Warning が `hookSpecificOutput.additionalContext` で
  Claude に届くようになった（従来の `systemMessage` は Claude に届いていなかった・#202 同型修正）。
  ③ `post-compact.sh` の stdout リマインダーを廃止し stderr ログに統一（PostCompact は stdout 注入
  非対応のため元々機能していなかった）
- **下流で必要な手動手順**: 通常は再適用のみで完結（自動同期）。`orchestrator-directive.sh` の
  注入本文（discussion-review スキル・agent-team-summary.md 前提の既定文言）を過去に直接編集して
  カスタマイズしていた下流のみ、再適用で上書きされる前に **カスタム本文を
  `.claude/orchestrator-directive.txt` へ移す**（以後は再適用で消えない）

## 2026-07-12（PR #203）daily-progress-rules.md を削除し user-notification-triage.md へ統合

- **変更内容**: `docs/rules/daily-progress-rules.md` を削除し、日次進捗レポートの構成を
  `docs/rules/user-notification-triage.md` §4.1 へ統合した（完了報告テンプレート重複の解消）
- **下流で必要な手動手順**: 自リポの `docs/rules/daily-progress-rules.md`（および
  `.claude/rules/daily-progress-rules.md` の symlink があればそれも）を手動削除する。
  同期はファイル削除を追従しないため、放置すると孤立ファイル化する。同ファイルを
  プロジェクト固有にカスタマイズしていた場合は、差分を `user-notification-triage.md` §4.1
  相当箇所へ移植してから削除する

## 2026-07-11（Issue #198 / PR #199）native-fallback 共通機構（Web 未提供機能の claude -p フォールバック）の新設

- **変更内容**: Web 未提供機能の native-first 判定 + `claude -p` フォールバック共通機構を追加
  （`tools/native_fallback.py`・`tools/native_capabilities.json`・`docs/rules/native-fallback-rules.md`・
  `modules.yaml` への配線）
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` のタスク依存ルール一覧に
  `native-fallback-rules.md` への参照を追加するか判断する（CLAUDE.md は保護対象のため
  自動反映されない）② 自リポ固有の Web ギャップ代替（isolation-by-design 対象）を棚卸しし、
  必要なら `tools/native_capabilities.local.json` オーバーレイを作成する（base の
  `native_capabilities.json` は同期で上書きされるため、フォーク固有差分は `.local.json` に書く）

## 2026-07-11（Issue #184 / PR #185 + #189）orchestrator-directive フック（高コストモデル検出時の専門チーム指示注入）の新設

- **変更内容**: 高コストモデル（Opus/Fable 系）検出時に「オーケストレーターとして専門チームを
  組成せよ」を UserPromptSubmit で自動注入する `orchestrator-directive.sh` を追加（#189 で
  正規表現検証・死にコード削除の堅牢化も実施）
- **下流で必要な手動手順**: `.claude/settings.json` を base 版に追従していない下流
  （`--keep-settings` 運用・独自 settings 管理）は、`UserPromptSubmit` フック配列の
  **guard → prompt-structuring → orchestrator-directive の順**（3 番目）で
  `orchestrator-directive.sh` を手動追加する（順序を誤ると二重バナー抑制が働かない。
  詳細はフックのヘッダーコメント参照）。トグル `CLAUDE_ORCHESTRATOR_DIRECTIVE` /
  判定正規表現 `CLAUDE_HIGH_COST_MODEL_RE` をプロジェクト方針に応じて設定するか判断する

## 2026-07-11（Issue #205）アップデート確認機構（base-sync-state マーカー + UPDATE NOTES）の導入

- **変更内容**: `apply-to-repo.sh` が適用完了時に `.claude/base-sync-state.json`
  （適用済みベースのコミット SHA・日時）を下流リポジトリへ記録し、再適用時に
  「前回適用以降の更新コミット一覧」と「本ノートの該当エントリ（手動手順が必要な更新）」を
  自動表示するようになった。`--check-updates` オプションで確認のみ（適用なし）も可能
- **下流で必要な手動手順**: なし（次回の適用で自動的にマーカーが作成される。
  マーカー `.claude/base-sync-state.json` はコミットして残すこと＝次回のアップデート確認の基準点になる）

## 2026-07-14（Issue #254 / PR #255）gh シム（クラウド 403 排除・GraphQL→REST 透過変換）の新設

- **変更内容**: クラウドの egress プロキシが repo スコープ REST を許可する挙動変化（2026-07-14 実測）を
  踏まえ、GraphQL 依存の gh 高レベルコマンドを REST へ透過変換する gh シム
  （`tools/gh_shim.py` + `.claude/bin/gh`）を追加。`session-start.sh` が `.claude/bin` を PATH 注入し、
  `stop-pr-check.sh` はクラウドでも REST で PR 存在を実検証、`generate_project_context.py` は
  クラウドで完全スナップショットを生成するようになった。SSOT
  （`github-mcp-fallback-patterns.md`・`lessons-core.md` L-114・CLAUDE.md の gh 節）も
  2026-07-14 実測マトリクスへ刷新
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` の gh 節（「クラウドでは MCP が一次経路」記述）を
  base 版（三層: シム + repo REST + MCP）に合わせて更新するか判断する（CLAUDE.md は保護対象のため
  自動反映されない）② `session-start.sh` を base 版に追従していない下流は、gh シム有効化ブロック
  （`.claude/bin` の PATH 注入・「gh シム有効化」コメント参照）を手動で移植する

## 2026-07-26（Issue #147）improvement-groomer を self-improvement-loop の整理モードへ統合

- **変更内容**: 改善 Issue 系スキルの責務境界を整理し、`improvement-groomer` スキルを削除して
  `self-improvement-loop` の **整理モード**（Step G-0〜G-5）として統合した（発見 / 整理 / 消化の 3 モード）。
  レーン境界の SSOT として `docs/rules/improvement-lane-map.md` を新設し、
  `retrospective` / `retro-try-handler` / `workflow-health-check` / `project-sync` の関係節を同ファイルの参照に置換。
  併せて `self-improvement-loop` 発見モードに Step 0.5（`workflow-health-check` 軽量版の実呼び出し）を追加し、
  「呼び出す」と書いてあるだけで実装がなかった連携を実装した。設計判断の記録は
  `docs/proposals/improvement-lane-consolidation.md`
- **下流で必要な手動手順**: ① 自リポの `.claude/skills/improvement-groomer/` を **手動削除** する
  （同期はファイル削除を追従しないため、放置すると孤立ファイル化し、統合後の
  `self-improvement-loop` とトリガーフレーズが衝突する）② 自リポの `CLAUDE.md` のスキル表から
  `improvement-groomer` 行を削除し、`self-improvement-loop` 行を 3 モード表記に更新する
  （CLAUDE.md は保護対象のため自動反映されない）③ 棚卸しをスケジュール実行に配線している下流は、
  起動フレーズを「`/self-improvement-loop --groom`（改善バックログを棚卸しして）」に差し替える。
  `tools/triage_improvements.py` は変更なしで存続するため差し替え不要

## 2026-07-26（Issue #323 / #324 / #325 / #326）Claude 5 世代向けコンテキストエンジニアリングの適用

- **変更内容**: Anthropic「The new rules of context engineering for Claude 5 generation models」を踏まえ、
  ① Hot 層（`.claude/rules/`）を 98,052 B → 65,867 B に再棚卸し（環境依存の障害カタログ L-079/L-080/L-101/L-106/L-114/L-117 を
  新設の `docs/rules/lessons/cloud-environment.md` へ Warm 降格し、Hot 側は症状ベースの索引 1 行に）、
  ② 同一規律の多重掲載を SSOT + 参照 1 行へ整理（応答スタイル＝ output style、完了報告＝ `completion-report-rules.md`、
  日時＝ `datetime-rules.md`、gh 403 ＝ `github-mcp-fallback-patterns.md`）、
  ③ `core-principles.md` CP-1 に「積極性は Issue 起票まで・コード変更は要求スコープ内」という衝突解決規則を追加、
  ④ `token-optimization-rules.md` の Hot 層予算を ~65KB / ~16,300 トークンへ改定（削減対象外の条件も明記）
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` の「応答スタイル」「セッション完了報告」「日時表記」「gh CLI」各節を
  base 版の縮約形（SSOT 参照 1 行スタイル）に合わせるか判断する（**CLAUDE.md は保護対象のため自動反映されない**）。
  縮約しない場合も、規律そのものは Hot 層ルール側に残るため動作は変わらない
  ② 自リポで独自に `lessons-core.md` を運用している場合、環境障害カタログを Warm 降格するかを判断する
  （降格の判定軸は「その規律を機械強制しているハーネス / スキル / ツールが既にあるか」）
  ③ Hot 層に独自ルールを追加している下流は、新予算 ~65KB を基準に
  `session-compression-rules.md`「新規ルールファイル追加時の必須手順」の予算チェックを回す
  ④ **（#326）自リポの `CLAUDE.md` から「スキル一覧表」を削除するか判断する**。Claude Code 本体が
  `The following skills are available for use with the Skill tool:` として各スキルの `description` 付きで
  自動列挙するため完全に重複しており、表を持つ限りスキルの追加・削除のたびに手動追従が必要になる
  （#147 の `improvement-groomer` 削除時に実際に発生）。ただし **`description` に載らないプロジェクト固有の
  ルーティング規則**（例: ほぼ同名スキルが共存するときの既定経路）は表を消した後も残すこと
  ⑤ **（#326）「やってはいけないこと」から汎用コーディング規範を削除するか判断する**。
  「タスク外のファイルを変更しない」「要求外でリファクタしない」は Claude Code 本体のシステムプロンプトが
  既に指示しているため（`The requested scope is the deliverable` / `Write code that reads like the surrounding code`）、
  重ねて書くと矛盾解決コストだけが増える。**本体が言っていないプロジェクト固有の禁止事項**
  （`main` 直 push・L-077・Intent Gate・L-113・`settings.local.json` の env 禁止）は残すこと
