# retrospective スキル — 詳細テンプレート集（reference）

> 🔴 **GitHub 操作の経路（必読・L-114）**: クラウド実行環境では `gh` がプリインストールされず、
> 導入しても repo スコープ REST が 403 になる。**本ファイル内の `gh ...` コマンドはローカル実行専用** で、
> クラウドでは `mcp__github__*` に読み替える（対応表: `docs/rules/github-mcp-fallback-patterns.md` §2。
> ラベル一覧/作成・マイルストーン・release 作成・variables は MCP に等価が無く **クラウドでは実行不可**・同 §2.5）。


> SKILL.md の各 Step が参照する詳細プロンプト・コマンド・出力テンプレートをまとめた補助ドキュメント。
> SKILL.md を汎用 KPT 手順中心に保つため、長文テンプレートは本ファイルに分離している（プログレッシブ・ディスクロージャ）。
> 必要な Step を実行する直前に該当セクションだけを Read する。
>
> 🔴 クラウド実行環境では repo スコープの `gh`（REST + GraphQL）が egress プロキシに 403 でブロックされる
> （L-114）。以下の GitHub 操作は GitHub MCP を一次経路とし、gh CLI 版は **ローカル環境向けの代替** として併記する。
> `list_issues` の複数ラベル指定は **OR**（gh の `--label A --label B` は AND）のため、MCP では単一ラベルで
> 取得し client-side で残りの条件を絞り込む（詳細: SSOT `docs/rules/github-mcp-fallback-patterns.md` §2.1）。

---

## A. Step 1: サブエージェント共通プロンプト構造

3 役割のサブエージェントに共通で渡すプロンプトの骨格。

```
あなたは {プロジェクト名} のワークフローの{role}です。
直近の {pipeline} パイプライン実行（対象: {entity_id}）を振り返り、
KPT（Keep/Problem/Try）を以下の形式で出力してください。

【実行コンテキスト】
{Step 0 で収集した情報}

【あなたの評価観点】
{役割別の評価観点リスト（下記 B〜D）}

【出力フォーマット（JSON）】
{KPT 出力フォーマット（下記 E）}
```

### B. 役割 1: 成果物品質レビュアー（model: haiku）

```
担当範囲: 成果物品質・キャラ/トーン一貫性・ドメイン固有の検証精度

評価観点:
- ドメイン固有の検証フラグの発生件数・解消率は適切だったか
- キャラ/トーン属性（プロジェクト定義・例: 口調・感情・表現）は適切だったか
- 成果物の目標（プロジェクト定義・例: 尺・分量）は達成されたか
- セルフレビュー・チームレビューで検出されたパターンはあったか
- AIレビュアー（Copilot 等）からの指摘傾向は何か
- プロジェクト定義のルール・設定シート（例: 制作ルール / キャラ設定）の遵守状況はどうか
```

### C. 役割 2: プロセス・自動化レビュアー（model: haiku）

```
担当範囲: ワークフロー効率・ボトルネック・自動化の有効性

評価観点:
- 各ステップで手動介入は必要だったか（ユーザー確認待ちの頻度）
- パイプライン中断・再実行は発生したか（原因は何か）
- スキップ可能・簡略化できるステップはあったか
- Issue / PR / Slack の連携は適切に機能したか
- 次回の同ワークフローでより効率化できる処理はあるか
- セッションタイムアウトリスクへの対応は十分だったか
```

### D. 役割 3: 技術・ツールレビュアー（model: haiku）

```
担当範囲: ツール・スクリプト・ドキュメントの整合性

評価観点:
- エラーパターン・リトライ発生状況と根本原因
- SKILL.md / CLAUDE.md に記載されていない新ルールが発見されたか
- ドキュメント（docs/rules/*.md）と実装の乖離はあるか
- 追加・修正すべきバリデーション・フック・品質ゲートはあるか
- self-review-checklist.md への追記候補はあるか
- 新たなエラーパターン（P-XX）として登録すべき指摘があるか
```

### Step 1.5: プロジェクト定義のレビュー役スポット監査（Lv1・ノンブロッキング）

> **実行条件**: 成果物の「本人らしさ」チェックの価値が高い特定パイプライン（プロジェクト定義）の完了後のみ実行する。その他パイプラインはスキップ。

3 役割エージェントと **同時に並列起動** し、本人視点の一言評価を収集する。レビュー役・禁止事項・参照成果物はプロジェクトで定義する。

**レビュー役A（Lv1・Sonnet・例: 技術正確性レビュー役）**:

```
参加レベル: Lv1

# 絶対禁止（プロジェクト定義のキャラ属性ガード）
- プロジェクトで禁止された方言・口調の混入禁止
- 「AIとして」等の自己開示禁止

# タスク（50文字以内で一言）
プロジェクト定義の成果物（例: content/.../{entity_id}_*.json）を Read して、
「今回の成果物に専門観点での深みが出ていたか」を一言で。
```

**レビュー役B（Lv1・Haiku・例: 初心者目線チェック役）**:

```
参加レベル: Lv1

# 絶対禁止（プロジェクト定義のキャラ属性ガード）
- プロジェクトで禁止された方言・口調の混入禁止
- 「AIとして」等の自己開示禁止

# タスク（50文字以内で一言）
プロジェクト定義の成果物（例: content/.../{entity_id}_*.json）を Read して、
「利用者として最後まで価値を感じられそうだったか」を一言で。
```

2人の一言コメントは Step 5（完了報告）の末尾に「本人コメント」として追記するのみ。KPT 判定には影響しない。

---

## E. KPT 出力フォーマット（全役割共通）

各サブエージェントは以下の JSON 形式で出力する。`{KPT 出力フォーマット}` の実体として使用する。

```json
{
  "keep": [
    {"title": "Keep アイテムのタイトル", "detail": "詳細説明"}
  ],
  "problem": [
    {"title": "Problem アイテムのタイトル", "detail": "詳細説明", "severity": "high|medium|low"}
  ],
  "try": [
    {
      "title": "Try アイテムのタイトル",
      "detail": "具体的な改善施策の説明",
      "assignee": "claude",
      "priority": "high",
      "estimated_effort": "small",
      "urgency": "quality",
      "done_type": "A-doc"
    }
  ]
}
```

**urgency フィールドの定義**:

| 値 | 意味 | 例 |
|----|------|----|
| `blocker` | パイプラインが止まる・データが壊れる致命的問題 | SSL エラー、タイムアウト、ファイル上書き |
| `quality` | 品質に影響するが即座には止まらない問題 | 成果物品質の低下、整合ズレ（プロジェクト定義） |
| `process` | 効率・自動化改善（品質には直接影響しない） | ソート順改善、ドキュメント構造整理 |
| `doc-only` | 説明・コメント・ルール文書のみの更新 | SKILL.md のわかりにくい表現を修正 |

**done_type フィールドの定義**:

| 値 | 意味 | 対応カテゴリ |
|----|------|------------|
| `A-doc` | ドキュメント更新で完結（SKILL.md / docs/rules/*.md / CLAUDE.md） | doc / skill |
| `B-script` | スクリプト実装が必要（`tools/*.py` / `tools/*.sh`） | script |
| `C-validate` | フック/バリデーター追加が必要（`post-tool-use-validate.sh` 等） | validate |
| `D-plan` | 実装計画のみ（large / 依存関係あり・今すぐ実装不可） | large issue |

---

## F. Step 3-A: 既存 Issue との重複チェック（OPEN → CLOSED/not_planned の 2 段）

Issue 作成前に、`type:retro-try` ラベルの既存 Issue と突合し、類似する Issue がないか確認する。
検索は **Step 3-0 で取得済みの 2 リスト**（`open_list` / `closed_list`）に対して行い、Try ごとに API を叩き直さない。

MCP（クラウド・一次経路・Step 3-0 で各 1 回だけ実行）:
```
open_list   = mcp__github__list_issues(owner, repo, state="OPEN",   labels=["type:retro-try"])
closed_list = mcp__github__list_issues(owner, repo, state="CLOSED", labels=["type:retro-try"], since={90 日前の ISO 8601 UTC})
              # 応答に state_reason は含まれない（fields は number/title/body/state/user/labels/assignees/comments/
              # created_at/updated_at/field_values のみ）。ここでは理由で絞らず、類似ヒット時に個別確認する（下記 2）
```

判定順:
1. `open_list` に類似あり → G（既存 Issue へコメント追記）
2. 1 で一致なし、かつ `closed_list` に類似あり → `mcp__github__issue_read(method="get", issue_number={N})` で `state_reason` を確認する
   （類似ヒット時のみの追加 1 呼び出し）:
   - `not_planned`（TTL クローズ済み・retro-try-handler Step 1.5 由来）→ **reopen**:
     `mcp__github__issue_write(method="update", issue_number={N}, state="open")`（**`labels` は渡さない**。渡さなければ全置換の
     対象にならず `status:waiting-claude` を含む元のラベルが保持される）。続けて G の再発検知テンプレートを投稿し、
     末尾に「TTL クローズ（not_planned）から再発により reopen」の 1 行を添える。reopen は Step 3 の起票上限・WIP 上限の対象
   - `completed`（実装済み）→ 退行として扱い、3 へ進む（新規作成。本文に「#N で実装済みの内容が再発」と記載）
3. どちらにも一致なし → H（新規作成。ただし Step 3 の起票上限・WIP 上限の範囲内のみ）

90 日窓（`since`）は closed Issue の全件検索コストを避けるための境界（数値の SSOT は `docs/rules/retrospective-rules.md`「WIP 制御」）。

ローカル環境（gh CLI 到達可能時）の代替:
```bash
gh issue list -R __OWNER__/__REPO__ \
  --label "type:retro-try" \
  --state open \
  --json number,title,body \
  --limit 1000
```

### 類似判定の基準

以下のいずれかに該当する場合、**類似 Issue あり** と判定する:

| 判定条件 | 例 |
|---------|-----|
| タイトルに **同じツール名・ファイル名** が含まれる | プロジェクト定義のツール・スクリプト名（例: `generate_*.py`） |
| タイトルに **同じ品質指標・フィールド名** が含まれる | プロジェクト定義の品質指標・フィールド名（例: ドメイン固有の検証フラグ） |
| タイトルに **同じワークフロー・ステップ名** が含まれる | 各パイプライン名・ステップ名（プロジェクト定義） |
| タイトルに **同じ問題パターン** を指している | 「〜を検証する」「〜をチェックする」といった表現が同じ対象を指している |

> **判定の迷い時の原則**: 同じファイル・ツール・フィールドを対象とした改善提案は、たとえ観点が少し異なっても「類似」として既存 Issue にまとめる。Issue の乱立を防ぎ、関連情報を一箇所に集約することを優先する。

---

## G. Step 3-B: 既存 Issue へのコメント追記（類似あり）

類似 Issue が見つかった場合、新規 Issue を作成せず既存 Issue にコメントで情報を追記する。

`mcp__github__add_issue_comment` を使用（`owner: "__OWNER__"` / `repo: "__REPO__"` / `issue_number: {既存Issueの番号}`）。

### コメントテンプレート

```markdown
## 再発検知（{YYYY-MM-DD} / {pipeline} パイプライン・{entity_id}）

同じ問題パターンが再び検出されました。

### 今回の発生状況

**ワークフロー**: {pipeline}（{entity_id}）
**担当レビュアー**: {role_name}

### 問題・課題

{対応する Problem の detail}

### 今回の改善提案

{try.detail}

### 再発回数

このコメントをもって {N} 回目の検知となります。優先度の引き上げを検討してください。

---
*レトロスペクティブスキルによる自動追記*
```

追記後、既存 Issue の番号を「コメント追記」として記録し、Step 5 の完了報告に含める。

> **優先度エスカレーション**: 同一 Issue に 3 回以上再発が確認された場合、既存 Issue の priority ラベルを `priority:high` に引き上げる（現在 high でなければ）。

---

## H. Step 3-C: 新規 Issue 作成（類似なし）

類似 Issue が見つからなかった場合のみ新規 Issue を作成する。`mcp__github__issue_write`（`method: "create"`）を使用する。

```
method: "create"
owner: "__OWNER__"
repo: "__REPO__"
title: "[Retro][{pipeline}] {try.title}"
labels: [
  "type:retro-try",                       # ← フィルタ用の主キー（必須）
  "type:improvement",
  "{try.estimated_effort を sp:N に写像}",  # small→sp:2 / medium→sp:3 / large→sp:5（session-sprint-rules.md §3.3・必須）
  "assignee:{try.assignee}",
  "priority:{try.priority}",
  "urgency:{try.urgency}",               # blocker / quality / process / doc-only
  "done_type:{try.done_type}",           # A-doc / B-script / C-validate / D-plan（done_type フィールドの値をそのまま使う）
  "status:waiting-{try.assignee}"        # assignee の値（claude/user）に応じて設定
]
body: （本文テンプレートに従って生成）
```

### Issue 本文テンプレート

```markdown
## 背景

**ワークフロー**: {pipeline}（{entity_id}）
**レトロスペクティブ日**: {YYYY-MM-DD}
**担当レビュアー**: {role_name}

## 問題・課題

{対応する Problem の detail（なければ「Try アイテムとして直接提案」）}

## 改善施策

{try.detail}

## 期待効果

- {具体的な改善内容}
- 再発防止・品質・自動化効率の向上

## 関連情報

- Pipeline PR: {pr_url}（あれば）
- 推定工数: {try.estimated_effort}（small / medium / large）
- 参考ルールファイル: {関連する docs/rules/ のファイル名}

---
*このIssueはレトロスペクティブスキルにより自動生成されました*
*フィルタ: `type:retro-try` ラベル（クラウド: `mcp__github__list_issues(labels=["type:retro-try"])` / ローカル: `gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --state open`）*
```

---

## I. Step 6: lessons 更新テンプレート

### 条件 A: 新規 Problem パターン — Warm 層への新規エントリ

**採番ルール**: `L-{N}` の N は全 lessons ファイル横断の最大番号 + 1 とする。

```bash
grep -rhoP 'L-\K[0-9]+' docs/rules/lessons-core.md docs/rules/lessons/ docs/rules/lessons-archive.md | sort -n | tail -1
```

で最大番号を取得し、重複・欠番を防ぐ。追記後にコミット:

```bash
git add docs/rules/lessons/{カテゴリ}.md
git commit -m "docs: lessons/{カテゴリ} L-{N} 追加（{パターン名}）（{pipeline} {entity_id}）"
git push
```

新規エントリのフォーマット:

```markdown
### L-{N}: {パターン名}（{YYYY-MM-DD}）

**パターン**: {繰り返し発生している問題の説明}

**根本原因**: {なぜ発生するのかの分析}

**試して失敗したアプローチ**:
- 初回発見のため記録なし

**対策**: {効果的だった解決策、または「要調査」}

**参照**: {関連Issue番号・PR番号}

**昇格先**: なし / {反映先}（昇格日: {YYYY-MM-DD}）
```

### 条件 B: 既存エントリと同パターンの再発

既存エントリの「**対策**:」セクション末尾に追記してコミット＆push:

```
同パターン再発: {YYYY-MM-DD}（{pipeline} {entity_id}）
→ Lv3（フック）への昇格を検討する
```

> **再発3回超の場合**: `type:retro-try` Issue を作成し（本文に関連する L-{N} を明記）、Lv3 フック（`.claude/hooks/post-tool-use-validate.sh`）への昇格を推奨する。

---

## J. Try Issue 対応フロー（別ワークフロー）

本スキルが作成した Try Issue は、以下のフィルタで次回実行時に取得・対応する（実際の対応は `retro-try-handler` スキルが担う）。

MCP（クラウド・一次経路）:
```
# 未対応の Try Issue を一覧取得（複数ラベルは OR のため単一ラベルで取得し client-side で AND 判定）
mcp__github__list_issues(owner, repo, state="OPEN", labels=["type:retro-try"])
  → 応答の labels に "status:waiting-claude" を含む Issue のみ対象にする

# 対応中にする（labels は全置換のため、現在のラベルから waiting-claude を除き in-progress を加えたフルリストを渡す・§2.2）
mcp__github__issue_write(method="update", issue_number=N, labels=[現在のラベル − "status:waiting-claude" ＋ "status:in-progress"])

# 対応完了でクローズ
mcp__github__add_issue_comment(owner, repo, issue_number=N, body="対応完了。{コミットハッシュ} で修正済み")
mcp__github__issue_write(method="update", issue_number=N, state="closed")
```

ローカル環境（gh CLI 到達可能時）の代替:
```bash
# 未対応の Try Issue を一覧取得
gh issue list -R __OWNER__/__REPO__ \
  --label "type:retro-try" \
  --label "status:waiting-claude" \
  --state open \
  --limit 1000

# 対応中にする（issue番号は実際の番号に置き換え）
gh issue edit {number} \
  --remove-label "status:waiting-claude" \
  --add-label "status:in-progress" \
  -R __OWNER__/__REPO__

# 対応完了でクローズ
gh issue close {number} \
  --comment "対応完了。{コミットハッシュ} で修正済み" \
  -R __OWNER__/__REPO__
```
