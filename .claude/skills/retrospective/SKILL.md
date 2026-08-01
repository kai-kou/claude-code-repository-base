---
name: retrospective
description: 各ワークフロー実行後に Agent Teams（3役割の並列サブエージェント）でレトロスペクティブを実施し、KPT（Keep/Problem/Try）を生成・Try アイテムを GitHub Issue 化する。各パイプライン（プロジェクト定義）の最終ステップから自動呼び出しされ、「レトロスペクティブして」「/retrospective」で手動実行も可能。KPT 生成・Try の Issue 化までが役割で、生成済み Try Issue の実装は retro-try-handler が担う。
effort: medium
---

> 🔴 **GitHub 操作の経路（必読・L-114）**: クラウド実行環境では `gh` がプリインストールされず、
> 導入しても repo スコープ REST が 403 になる。**本ファイル内の `gh ...` コマンドはローカル実行専用** で、
> クラウドでは `mcp__github__*` に読み替える（対応表: `docs/rules/github-mcp-fallback-patterns.md` §2。
> ラベル一覧/作成・マイルストーン・release 作成・variables は MCP に等価が無く **クラウドでは実行不可**・同 §2.5）。


# レトロスペクティブスキル

ワークフロー完了後に KPT レトロスペクティブを自動実施し、Try アイテムを Issue 化する汎用スキル。

- 詳細ルール: `docs/rules/retrospective-rules.md`
- 詳細プロンプト・コマンド・出力テンプレート: 本スキルの `reference.md`（各 Step 実行直前に該当セクションだけを Read する）

> 🔴 クラウド実行環境では repo スコープの `gh`（REST + GraphQL）が egress プロキシに 403 でブロックされる（L-114）。
> 本スキルの GitHub 操作は GitHub MCP（`mcp__github__*`）を一次経路とし、`gh` コマンド例は **ローカル環境向けの代替** として読む
> （SSOT: `docs/rules/github-mcp-fallback-patterns.md`）。

## トリガー条件

- 各パイプライン（プロジェクト定義）の最終ステップから自動呼び出し
- 「レトロスペクティブして」「振り返りして」「KPTして」「/retrospective」
- `/retrospective {pipeline} {ID}` のように対象を指定して手動実行
- **パイプライン失敗時にも自動トリガー（「根本原因を特定して再発防止してください」不要）**: 同一エラーパターン2回以上 / サーキットブレーカー発動（AIレビュー修正サイクル2回超）/ 品質ゲート未達 / セルフレビュー Error 未解消

### 失敗時レトロスペクティブの判断基準

| 状況 | 自動実行するか |
|------|-------------|
| パイプライン完了（成功） | ✅ 毎回実行 |
| サーキットブレーカー発動 | ✅ 自動実行（STOP直後） |
| 同一エラー2回目以降 | ✅ 自動実行 |
| 品質ゲート未達（プロジェクト定義の閾値） | ✅ 自動実行（ユーザー報告の前に） |
| 1回限りの軽微なエラー（リトライで解決） | ⬜ スキップ可 |

**失敗時に `type:retro-try` Issue を生成することで、再発防止策が自動で蓄積される。** これにより「根本原因を特定して再発防止してください」はユーザーが言わなくてよい指示になる。

## 前提条件

- 対象ワークフローの実行が完了またはサーキットブレーカーで停止していること（未完了でも失敗レトロ目的で実行可）
- GitHub MCP（`mcp__github__issue_write`）が利用可能で、`type:retro-try` ラベルが作成済みであること

## 実行フロー概要

```
Step 0: コンテキスト収集（git log・PR情報・品質メトリクス）
  ↓
Step 1: Agent Teams 起動（3役割を並列サブエージェント・全て haiku）
  ├── 成果物品質レビュアー
  ├── プロセス・自動化レビュアー
  └── 技術・ツールレビュアー
  （Step 1.5: プロジェクト定義のレビュー役スポット監査・特定パイプラインのみ・並列）
  ↓
Step 2: KPT 結果のマージ・重複統合
  ↓
Step 3: Try アイテムを GitHub Issue 化（重複チェック → 追記 or 新規作成）
  ↓
Step 4: Slack 通知 → Step 5: 完了報告 → Step 6: lessons 更新チェック
```

---

## Step 0: コンテキスト収集

パイプラインから渡されたパラメータ（`pipeline` / `entity_id` / `pr_url` / `execution_summary`）を受け取り、補足情報を収集する。手動実行時はパラメータ未指定でも可（直近の git log から推測）。

```bash
git log --oneline -20   # 直近20コミット
git status              # ステージ・作業ツリーの状態
# pr_url が渡された場合は mcp__github__pull_request_read で PR 情報を取得
```

直近コミット・PR から品質メトリクスを読み取る: ドメイン固有の検証フラグ件数（該当パイプラインのみ）・セルフレビュー Error/Warning 件数・AIレビュー指摘件数・中断/リトライ発生有無。

---

## Step 1: Agent Teams 起動（3役割を並列実行）

以下の3つのサブエージェント（全て model: haiku）を `Agent` ツールで **同時に並列起動** する。各役割の担当範囲は次のとおり:

| 役割 | 担当範囲 |
|------|---------|
| 成果物品質レビュアー | 成果物品質・キャラ/トーン一貫性・ドメイン固有の検証精度 |
| プロセス・自動化レビュアー | ワークフロー効率・ボトルネック・自動化の有効性 |
| 技術・ツールレビュアー | ツール・スクリプト・ドキュメントの整合性 |

- 共通プロンプト構造・役割別の詳細評価観点リスト → `reference.md` の A〜D
- 各役割は KPT を JSON 形式で出力する（出力フォーマット・`urgency`/`done_type` フィールド定義 → `reference.md` の E）
- **Step 1.5**（プロジェクト定義のレビュー役スポット監査・特定パイプラインのみ）も同時に並列起動する → `reference.md` の Step 1.5。本人視点の一言は Step 5 完了報告の末尾に添えるのみで KPT 判定には影響しない

---

## Step 2: KPT 結果のマージ

3つのサブエージェントの JSON 結果を統合する。

1. **Keep / Problem の統合**: 役割別にカテゴライズして一覧化する
2. **Try の統合・重複排除**: 複数役割から同じ改善案が出たら1つにまとめ、最も高い `priority` を採用し、`detail` に両方の視点を記載する

---

## Step 3: Try アイテムを GitHub Issue 化

統合済みの全 Try アイテムを `high` → `medium` → `low` の順に処理する。各アイテムごとに:

```
Step 3-A: 既存オープン Issue との重複チェック（type:retro-try を検索）
  ├── 類似 Issue あり → Step 3-B: 既存 Issue にコメント追記
  └── 類似 Issue なし → Step 3-C: 新規 Issue を作成
```

- **3-A** 検索コマンド・類似判定の基準 → `reference.md` の F
- **3-B** コメント追記コマンド・再発検知テンプレート（3回超で priority:high へエスカレーション）→ `reference.md` の G
- **3-C** `mcp__github__issue_write` の labels 構成（`sp:N` 写像必須）・本文テンプレート → `reference.md` の H

### Step 3 完了後の記録

全 Try アイテムの処理結果を Step 5 の完了報告に含める:

| 結果 | 記録内容 |
|------|---------|
| 新規 Issue 作成 | Issue 番号・URL |
| 既存 Issue へコメント追記 | 既存 Issue 番号・URL・「コメント追記」の旨 |
| 優先度エスカレーション実施 | 対象 Issue 番号・変更前後の priority |

---

## Step 4: Slack 通知

```bash
python3 "${CLAUDE_PROJECT_DIR}/tools/slack_notify.py" pipeline \
  --pipeline "レトロスペクティブ（{pipeline}）" \
  --video-id "{entity_id}" \
  --result "完了（Keep {K}件 / Problem {P}件 / Try {T}件→Issue#{N1},#{N2},...）" \
  --duration "{所要時間}"
```

> `--video-id` は `slack_notify.py` の既存引数名（レガシー）だが、値は対象エンティティ ID（`{entity_id}`）を汎用的に渡す。動画以外のワークフローでも識別子としてそのまま使ってよい。

Slack 通知に失敗しても処理を中断しない（無音でスキップ）。

---

## Step 5: 完了報告

以下のフォーマットで出力する:

```
## レトロスペクティブ完了報告

### ワークフロー
- パイプライン: {pipeline} / 対象 ID: {entity_id} / 実施日: {YYYY-MM-DD}

### KPT サマリー
#### ✅ Keep（うまくいったこと）
{役割別 Keep の一覧（箇条書き）}
#### ⚠️ Problem（問題・改善が必要なこと）
{役割別 Problem の一覧（箇条書き）}
#### 🚀 Try（改善施策）→ Issue 化済み
{Try の一覧（Issue #N リンク付き、コメント追記は「既存 Issue #N へ追記」と明記）}

### Try Issue 一覧取得
mcp__github__list_issues(owner, repo, state="OPEN", labels=["type:retro-try"])   # クラウド一次経路
（ローカル: gh issue list -R __OWNER__/__REPO__ --label "type:retro-try" --state open）
```

---

## Step 6: lessons 更新チェック（肥大化防止）

新しい Problem パターンが発見された場合に **Warm 層**（`docs/rules/lessons/{カテゴリ}.md`）を更新する。**Hot 層（`docs/rules/lessons-core.md`）には原則追記しない**（全セッション横断で必須かつ作業停止級のクリティカル規範のみ・上限 350 行 / 15 件で機械強制）。詳細は `docs/rules/lessons-management.md`（SSOT）。

- **条件 A（新規パターン）**: 適切なカテゴリ（`pipeline` / `pr-review` / `content` / `session` / `agent` / `meta` 等）の Warm 層ファイルに新規 `L-{N}` エントリを追記する。判定基準は「既存と異なる（`tools/lessons_guard.py dedup` で確認）・2回以上発生・自動化で防げた問題」。採番ルール・エントリフォーマット → `reference.md` の I
- **条件 B（既存パターン再発）**: 既存エントリの「対策」末尾に再発日を追記。3回超は `type:retro-try` Issue 化 + Lv3 フック昇格を推奨 → `reference.md` の I
- **条件 C（新規・再発なし）**: スキップし、完了報告に「lessons.md 更新なし」と明記する

---

## エラーハンドリング

| エラー | 対応 |
|--------|------|
| コンテキスト情報が不足 | git log と git status から可能な範囲で推測して続行 |
| サブエージェント失敗（1役割） | 残り2役割の結果で続行。失敗した役割を完了報告に明記 |
| サブエージェント全失敗 | STOP。ユーザーに手動レビューを依頼 |
| Issue 作成失敗 | 失敗した Try のタイトルを完了報告に列挙し、手動作成を依頼 |
| `type:retro-try` ラベル未存在 | ローカル: `gh label create "type:retro-try" --color "c5def5" -R __OWNER__/__REPO__` で作成してリトライ。クラウドは 403 かつ MCP にラベル作成の等価ツールがないため、ユーザーにローカル実行を案内する |
| Slack 通知失敗 | 無音でスキップ（エラーにしない） |

---

## 手動実行・呼び出し

```
/retrospective {pipeline} {ID}   # 特定パイプラインの振り返り（対象指定）
/retrospective                   # 全ワークフロー共通（最新コミットから推測）
```

各パイプライン（プロジェクト定義）からは、完了報告（最終ステップ）の **後に** 本スキルを呼び出す（`pipeline` / `entity_id` / `pr_url` / `execution_summary` を渡す）。本スキルが作成した Try Issue の対応フロー → `reference.md` の J（実際の実装は `retro-try-handler` スキルが担う）。

## 既存スキルとの関係

> レーン境界（改善 Issue / 振り返り / 監査・衛生）の SSOT は `docs/rules/improvement-lane-map.md`。
> 本スキルは **振り返りレーン** の上流（KPT 生成・Try 起票）で、`type:retro-try` の実装は下流の
> `retro-try-handler` が担う。`type:improvement` の起票・棚卸し・実装は改善 Issue レーン
> （`self-improvement-loop`）の担当で、本スキルは扱わない。

| 関連スキル | 関係 |
|-----------|------|
| 各パイプライン（プロジェクト定義） | 各工程の完了後に本スキルを呼び出す |
| `retro-try-handler` | 本スキルが起票した `type:retro-try` Issue を実装・PR 化する |
| `self-reviewer` | Try に `self-review-checklist.md` 追記候補が含まれる場合、対応する Try Issue を作成 |
| `project-manager` | Try Issue の Projects V2 への登録が必要な場合に参照 |
