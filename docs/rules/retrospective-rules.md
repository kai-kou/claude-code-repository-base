# レトロスペクティブルール

各ワークフロー（パイプライン）実行後に Agent Teams でレトロスペクティブを実施し、
Try アイテムを GitHub Issue 化するルール。

## 概要

| 項目 | 内容 |
|------|------|
| 実行タイミング | 各パイプラインの最終ステップ（自動）または手動 `/retrospective` |
| フレームワーク | KPT（Keep / Problem / Try） |
| Agent Teams 構成 | 3 役割を並列サブエージェントで担当 |
| Try の Issue 化 | 全 Try アイテムを自動で GitHub Issue 化 |
| フィルタ用ラベル | `type:retro-try` で一覧取得可能 |

## 対象ワークフロー

| パイプライン | 呼び出しタイミング |
|-------------|-----------------|
| `script-pipeline` | 台本 PR マージ後（Step 9 の末尾） |
| `audio-pipeline` | 音声 PR マージ後（完了報告の末尾） |
| `image-pipeline` | 画像 PR マージ後（完了報告の末尾） |
| `video-pipeline` | 動画 PR マージ後（完了報告の末尾） |

手動実行: 「レトロスペクティブして」または `/retrospective` で任意タイミングに実行可能。

## Agent Teams 役割定義

3 つの専門レビュアーを **並列サブエージェント** として起動する。

### 役割 1: コンテンツ品質レビュアー

```
担当範囲: コンテンツ品質・キャラクター一貫性・ファクトチェック精度
評価観点:
  - fact_check_flags の発生件数・解消率
  - キャラクター設定（方言・感情・アクション）の遵守状況
  - 台本の尺目標達成状況（VOICEVOX 実測）
  - セルフレビュー・チームレビューで検出された問題パターン
  - AIレビュアーからの指摘の傾向と頻度
```

### 役割 2: プロセス・自動化レビュアー

```
担当範囲: ワークフロー効率・ボトルネック・自動化の有効性
評価観点:
  - 各ステップの所要時間・スキップ可能なステップの特定
  - 手動介入が必要だった箇所（ユーザー確認待ちの頻度）
  - パイプライン中断・再実行の発生有無とその原因
  - Issue / PR / Slack の連携が適切に機能したか
  - 次回の同ワークフローで省略・簡略化できる処理の提案
```

### 役割 3: 技術・ツールレビュアー

```
担当範囲: ツール・スクリプト・ドキュメントの整合性
評価観点:
  - エラーパターン・リトライ発生状況
  - SKILL.md / CLAUDE.md に記載されていない新ルールの発見
  - ドキュメント（docs/rules/*.md）と実装の乖離
  - 追加・修正すべきバリデーション・フック・品質ゲート
  - セルフレビュー学習ログ（self-review-learnings.md）への追記候補
```

## KPT 出力フォーマット

各サブエージェントは以下の JSON 形式で結果を返す。

```json
{
  "role": "quality | process | technical",
  "pipeline": "script | audio | image | video",
  "video_id": "V001",
  "keep": [
    { "title": "うまくいった点の要約", "detail": "具体的な説明" }
  ],
  "problem": [
    { "title": "問題点の要約", "detail": "具体的な問題の説明と影響" }
  ],
  "try": [
    {
      "title": "改善施策の要約（Issue タイトルに使用）",
      "detail": "具体的な改善案・実装方法・期待効果",
      "priority": "high | medium | low",
      "assignee": "claude | user",
      "estimated_effort": "small | medium | large"
    }
  ]
}
```

## Try アイテムの Issue 化ルール

### Issue タイトル命名規則

```
[Retro][{pipeline}] {Try内容の要約}
```

例:
- `[Retro][script] fact_check_flags の自動解消率をセルフレビューで検出する`
- `[Retro][audio] 発音辞書カバレッジチェックを音声生成前に必ず実行する`
- `[Retro][image] サムネイル評価スコアを PR 説明文に自動掲載する`
- `[Retro][video] レンダリング前の BGM トラック検証ステップを追加する`

### Issue ラベル

| ラベル | 付与条件 |
|--------|---------|
| `type:retro-try` | 全 Try Issue に必須（**フィルタ用の主キー**） |
| `type:improvement` | 全 Try Issue に付与 |
| `assignee:claude` | `assignee: "claude"` の場合 |
| `assignee:user` | `assignee: "user"` の場合 |
| `priority:high` | `priority: "high"` の場合 |
| `priority:medium` | `priority: "medium"` の場合 |
| `priority:low` | `priority: "low"` の場合 |
| `status:waiting-claude` | `assignee: "claude"` の場合 |
| `status:waiting-user` | `assignee: "user"` の場合 |

### Issue 本文テンプレート

```markdown
## 背景

**ワークフロー**: {pipeline}（{video_id}）
**レトロスペクティブ日**: {date}
**担当レビュアー**: {role}

## 問題・課題

{problem の detail（対応する Problem があれば引用）}

## 改善施策

{try の detail}

## 期待効果

- {具体的な改善内容}
- 再発防止・品質向上への貢献

## 関連情報

- Pipeline PR: {pr_url}（あれば）
- 推定工数: {estimated_effort}
- 参考ルールファイル: {docs/rules/ の関連ファイル}

---
*このIssueはレトロスペクティブスキルにより自動生成されました*
```

### Issue フィルタリング方法

Try Issue を一覧で取得する。クラウドは MCP 一次経路（L-114）:
`mcp__github__list_issues(owner, repo, labels=["type:retro-try"], state="OPEN")`
（複数ラベル AND・タイトル検索は応答を client-side でフィルタする・`github-mcp-fallback-patterns.md` §2.1）。
以下の gh コマンドはローカル実行用:

```bash
# 全 Try Issue を取得
gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --state open

# Claude 担当の Try のみ
gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --label "assignee:claude" --state open

# 特定パイプラインの Try のみ（タイトル検索）
gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --search "[Retro][script]"

# 高優先度の Try のみ
gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --label "priority:high" --state open
```

## レトロスペクティブ実行フロー

### Step 0: コンテキスト収集

実行直前のパイプライン情報を収集する:

1. **git log** で直近のコミット一覧を取得（`git log --oneline -20`）
2. **PR 情報**: マージ済みの PR タイトル・URL・コミット数
3. **実行サマリー**: パイプライン種別、動画 ID、所要ステップ数、発生エラー件数
4. **品質メトリクス**: fact_check_flags 件数、セルフレビュー Error/Warning 件数、AIレビュー指摘件数

### Step 1: Agent Teams 起動（並列）

3 つのサブエージェントを **同時に** 起動する。各エージェントに以下を渡す:

```
コンテキスト情報（Step 0 で収集した情報）
+ 担当役割（quality / process / technical）
+ 評価観点リスト（本ドキュメントの「役割定義」参照）
+ KPT 出力フォーマット（本ドキュメント参照）
```

モデル選択: `model="haiku"`（チェック・評価系タスク）

### Step 2: KPT 結果のマージ

3 つのサブエージェントの結果を統合する:

1. Keep を役割別にまとめる
2. Problem を役割別にまとめる
3. **Try を全役割から収集** し、重複・類似アイテムを統合する

### Step 3: Try アイテムの Issue 化

WIP 制御（本ファイル「WIP 制御」節・#563）の範囲内で GitHub Issue を作成する:

1. オープン `type:retro-try` 件数を 1 回取得し、WIP 上限（30 件）以上なら追記のみモード（新規作成なし）
2. 優先度 `high` のアイテムから順に処理し、類似した Try は既存 Issue へのコメント追記（または TTL クローズ済み Issue の reopen）にまとめる
3. 類似がない Try のみ `mcp__github__issue_write` で Issue を作成する（1 回のレトロで最大 3 件・`urgency:blocker` は上限外）
4. 作成した Issue 番号と、見送った Try（起票上限 / WIP 上限）を記録する

### Step 4: Slack 通知

```bash
python3 "${CLAUDE_PROJECT_DIR}/tools/slack_notify.py" pipeline \
  --pipeline "レトロスペクティブ（{pipeline}）" \
  --video-id "{video_id}" \
  --result "完了（Keep {K}件 / Problem {P}件 / Try {T}件→Issue化）" \
  --duration "{所要時間}"
```

### Step 5: 完了報告

以下の形式でレポートを出力する:

```
## レトロスペクティブ完了報告

### ワークフロー
- パイプライン: {pipeline}
- 動画 ID: {video_id}
- 実施日: {date}

### KPT サマリー

#### ✅ Keep（うまくいったこと）
{Keep の一覧}

#### ⚠️ Problem（問題・改善が必要なこと）
{Problem の一覧}

#### 🚀 Try（次回への改善施策）→ Issue 化済み
{Try の一覧（Issue #N へのリンク付き）}

### 次のアクション
- Try Issue の対応: クラウドは `mcp__github__list_issues(labels=["type:retro-try"], state="OPEN")`（L-114）/ ローカルは `gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --state open`
```

## WIP 制御（発生・在庫・出口の数値 SSOT・#563）

> **このセクションが振り返りレーンの WIP 制御に関する数値の唯一の定義**。各 SKILL.md はここを参照し、数値を再定義しない。
> 背景: 「振り返り = Try を全件 Issue 化する」設計は WIP 制限のない PUSH 型で、到着率 λ がパイプライン回数に比例して
> 無制限に伸びる一方、消化側は上限つきのため在庫 L = λW（リトルの法則・Little 1961）が単調増加する。
> 消化上限の引き上げだけでは λ が上回る限り解決しない。設計議論は `content/discussions/retro-issue-overflow-20260904/`。

| 制御点 | 値 | 実装先 | 根拠 |
|--------|-----|--------|------|
| **起票上限**（1 回のレトロで新規 Issue 化する Try） | **3 件**（`urgency:blocker` は上限外。priority high → medium の順に採用し、超過分は完了報告の「見送り Try」に記録） | `retrospective` Step 3 | Kanban の WIP 制限（Anderson『Kanban』2010）・スクラムガイド 2020「最もインパクトの大きい改善だけをスプリントバックログへ」 |
| **WIP 上限**（オープン `type:retro-try` の累積） | **30 件**（以上で `retrospective` が「追記のみモード」= 新規 Issue 作成を停止し既存 Issue への追記のみ行う） | `retrospective` Step 3-0 | プルシステムは「引く場所」で WIP を強制する（同上）。`retro-try-handler` の処理上限表「30 件以上」・`workflow-health-check` 5-a の 30 件 Warning と同じ数値 |
| **TTL 出口**（未着手 Try の自動クローズ） | **30 日** 更新なし（`status:waiting-claude` かつ `urgency:blocker` でない Issue を `not_planned` でクローズ。1 回の実行で最大 **5 件**） | `retro-try-handler` Step 1.5 | 出口のない在庫は L を単調増加させる。`workflow-health-check` 5-e の「30 日で沈黙」と同じ数値 |
| **再発 reopen 窓** | **90 日**（TTL でクローズされた Issue と同種の Try が再検出されたら reopen して再発コメント） | `retrospective` reference.md F | 誤クローズの回復コストを下げ TTL を安全側に倒す |

上限値を変えるときは **本表を先に更新** し、各 SKILL.md / reference.md が出典明記のうえ再掲している値を **同一 PR で更新する**
（再掲箇所は `grep -rn "WIP 制御" .claude/skills docs/rules` で列挙できる。参照なしの独立した数値定義は作らない）。
下流プロジェクトが値を変える場合も同様で、`project-mission.md` に上書き値を書く場合はここを参照させる。

## 禁止事項

- Try アイテムを Issue 化せずに「次回気をつける」で済ませない（**例外**: 上記 WIP 制御の起票上限・WIP 上限で見送った Try は Issue 化しないが、完了報告の「見送り Try」に **記録は残す**。記録が残る限り本条項の対象外）
- 同じ Problem が 2 回以上繰り返されても新しい Try Issue を作らないでいる（**例外**: WIP 上限中は既存 Issue への再発コメント追記で代替する。TTL クローズ済み Issue は新規作成ではなく reopen で扱う）
- 1 回のレトロで起票上限（3 件）を超えて新規 Issue を作る・WIP 上限（30 件）以上の状態で新規 Issue を作る（在庫の発散を防ぐ WIP 制御の無効化）
- KPT を 3 役割の並列実行ではなく逐次実行する（並列化必須）
- `type:retro-try` ラベルなしで Try Issue を作成する（フィルタリングが機能しなくなる）
