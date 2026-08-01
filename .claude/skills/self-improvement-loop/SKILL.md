---
name: self-improvement-loop
description: プロジェクト全体を定期的に横断レビューし、根本原因特定→改善Issue起票→棚卸し（集計・重複統合・Epic化・priority/sp 補完）→最優先即実装→マージまで自律実行するセルフ改善オーケストレーター。発見（定期の N 観点横断レビュー）・整理（溜まった type:improvement の棚卸し）・消化（改善Issueの高速処理）の3モードで動く。「セルフ改善して」「横断レビューして」「プロジェクト改善して」「改善Issueを棚卸しして」「改善バックログを整理して」「Epic化して」「改善Issue消化して」「/self-improvement-loop」と依頼された時、またはプロジェクト定義の発見スロット / 日次消化スロットで自動実行する。type:retro-try（振り返り由来の Try）は retro-try-handler、Issue/PR の状態・衛生は workflow-health-check / project-sync が担当する。
effort: medium
---

> 🔴 **GitHub 操作の経路（必読・L-114）**: クラウド実行環境では `gh` がプリインストールされず、
> 導入しても repo スコープ REST が 403 になる。**本ファイル内の `gh ...` コマンドはローカル実行専用** で、
> クラウドでは `mcp__github__*` に読み替える（対応表: `docs/rules/github-mcp-fallback-patterns.md` §2。
> ラベル一覧/作成・マイルストーン・release 作成・variables は MCP に等価が無く **クラウドでは実行不可**・同 §2.5）。


# self-improvement-loop スキル

## 目的

プロジェクト全体（プロジェクト定義の N 観点・例: パイプライン健全性・リポジトリ衛生・成果物品質・コードベース・戦略 等）を定期的に横断レビューし、**個別症状ではなくメタ根本原因** を特定して、改善Issueの起票・棚卸し・実装・マージまでを自律実行する。

ユーザーが状況を確認しに来なくても、**課題発見 → 改善実装 が定期的に回る** 状態を維持する（CP-6 Human-on-the-loop）。

## 設計方針：改善 Issue のライフサイクルを 1 スキルで持つ

本スキルは「改善 Issue の世話」（起票 → 整理 → 実装）を **1 スキル 3 モード** で担う（Issue #147 の統合。旧 `improvement-groomer` スキルは整理モードとして本スキルに統合済み）。

| モード | 役割 | 頻度 | コスト |
|--------|------|------|--------|
| **発見モード** | N 観点の並列横断レビューで新規課題を発掘し改善Issueを起票 | 定期（プロジェクト定義の発見スロット） | 高（並列サブエージェント） |
| **整理モード** | 溜まった `type:improvement` の棚卸し（集計・重複統合・Epic 化・priority/sp 補完） | 滞留時（30 件超）/ 月次 | 中 |
| **消化モード** | 起票済み改善Issueを優先度順に高速消化（実装 → PR → マージ） | 日次（プロジェクト定義の消化スロット） | 低〜中 |

**長期放置防止**: 発見（在庫生成）と消化（処理）を分離し、消化を日次・複数件で回すことで改善スループットを最大化する。在庫が積み上がって「多すぎて選べない」状態になったら整理モードを挟む。改善Issueは作成後 **7日で必ず再評価**（project-sync が検出）。

## 他レーンとの境界

責務境界の SSOT は **`docs/rules/improvement-lane-map.md`**（本ファイルでは再定義しない）。要点のみ:

- `type:retro-try` は **振り返りレーン**（`retrospective` → `retro-try-handler`）の担当。本スキルの消化モードは扱わない（奪い合い防止・#160）
- Issue / PR の **状態**（ラベル不整合・Stale・Orphan）は **監査・衛生レーン**（`workflow-health-check` → `project-sync`）の担当
- 監査結果は再監査せず参照する。発見モード Step 0.5 で `workflow-health-check`（軽量版）を実際に呼び出して入力にする（宣言だけの連携をしない）

---

## 発見モード実行フロー（定期・プロジェクト定義の発見スロット）

### Step 0: 前提チェック
```
- gh CLI 動作確認（which gh）。不在なら L-086 に従い session-start.sh の gh インストール成否を確認
- git log / project_state.md で現状把握
```

### Step 0.5: 監査レーンの結果取得（重複監査の回避）

`Skill(workflow-health-check)` を **軽量版**（`--light`・Step 1 PR 健全性 + Step 2 Issue 状態）で実行し、その検出結果（放置 PR・スタック Issue・ラベル不整合）を Step 1 の観点 2（パイプライン健全性）・観点 3（リポジトリ衛生）の **入力として渡す**。本スキルは同種の監査を再実行しない。

> 軽量版が失敗した場合（API エラー等）は監査結果なしで Step 1 に進み、その旨を Step 5 の報告に明記する（発見モード全体は止めない）。

### Step 1: N 観点の並列サブエージェントレビュー
N 体を **1メッセージで並列起動**（model=sonnet 推奨・客観性重視）。各エージェントに自己完結プロンプト + 「強み2-3 / 重大問題3-5（根拠データ必須）/ 改善提案（優先度付き）/ 100点満点スコア」を 800字以内で要求する。

> **観点はプロジェクトで定義する**。下表は汎用テンプレート（プレースホルダ）。各プロジェクトは `docs/project-mission.md` の KPI・ドメインに合わせて観点・調査対象を差し替える（ミッション KPI・パイプライン・成果物品質・キャラ/トーン属性 等）。

| # | 観点（テンプレート） | subagent_type | 主な調査対象（プロジェクト定義） |
|---|------|--------------|------------|
| 1 | ミッション KPI・成長 | general-purpose | プロジェクト定義の分析データ（例: content/analytics/）, メタ情報 |
| 2 | パイプライン健全性 | general-purpose | .claude/skills/*pipeline*, lessons-core.md, discover系ツール, git log, **Step 0.5 の監査結果** |
| 3 | リポジトリ衛生・PM | general-purpose | GitHub MCP（list_issues/PR・status別内訳・滞留日数）, **Step 0.5 の監査結果** |
| 4 | 成果物品質・キャラ/トーン一貫性 | general-purpose | プロジェクト定義の成果物（例: ドメイン固有の検証項目・キャラ属性）, 検証スクリプト |
| 5 | 技術アーキ・コードベース | general-purpose | tools/（規模・重複・死蔵）, tests/, .github/workflows/, requirements |
| 6 | 戦略・利用者価値 | プロジェクト定義のレビュー役（Lv3） | 分析データ, リサーチ資料, 成果物一覧 |

### Step 2: メタ根本原因の特定
- N 観点の所見を統合し、**複数の症状にまたがる共通の根** を3層因果分析（直接/中間/根本）で特定する
- 「個別Issueの寄せ集め」ではなく「1つの根が複数症状を生んでいないか」を最優先で探す
- 必要なら裏取り（実機コマンド・grep）で根本原因を確定する

### Step 3: 改善Issue起票（重複チェック必須）
```
1. 既存オープンIssueを検索（クラウド一次: `mcp__github__search_issues(query, owner, repo)` / ローカル: `gh issue list` 等）し、同一根本原因のIssueが無いか確認
2. 重複が無ければ起票:
   - title: feat:/fix:/improvement: {根本原因に対する対策}
   - labels: type:{feature/bug/improvement} + priority:{high/medium/low} + sp:{2/3/5}（small/medium/large 相当を写像・session-sprint-rules.md §3.3・必須）
   - body: 背景 / 根本原因(3層) / 対応方針 / 完了条件 / 再発防止
3. Issue乱発を避ける（1根本原因=1Issue・refinement の命名規約に準拠）
```

### Step 4: 最優先1件を即実装 → マージ
- priority:high かつ実装コスト小・効果大の1件を選ぶ
- status:in-progress 付与（CP-4 論理ロック）→ 実装 → 効果を実機検証 → コミット → PR → AIレビュー → 自動マージ
- L-086 等のレッスン記録が必要なら lessons に追記

### Step 5: 報告
- 特定した根本原因・起票Issue一覧・実装した最優先課題を Slack/完了報告で出力（L-076 アウトカム形式）

---

## 整理モード実行フロー（棚卸し・grooming）

> **目的**: 溜まった `type:improvement` を棚卸しし、「データなき量産」状態を解消して、消化モードに渡せる整然としたバックログを維持する。
> **2 層構成**: `tools/triage_improvements.py`（重い集計・**読み取り専用**）+ 本フロー（Claude の判断）。

### Step G-0: ロック取得（CP-4）

棚卸しは Issue 群を変更するため、作業 Issue を 1 件（`feat: 改善Issue棚卸し YYYY-MM-DD` 等）作って `status:in-progress` を付与するか、ユーザー指示由来の既存 Issue にロックを取る。スケジュール起動時は直近の棚卸し Issue がオープンでないか確認する（重複起動防止）。

### Step G-1: レポート生成（コード）

```bash
python3 tools/triage_improvements.py --out /tmp/groom_report.md   # Markdown
python3 tools/triage_improvements.py --json > /tmp/groom.json     # 機械処理用
```

レポートの内容: **集計**（priority / sp / 監査フェーズの分布）・**カテゴリ別件数**（監査タグ優先、なければキーワードクラスタ）・**Epic 統合候補**（同一カテゴリに `--epic-threshold`〔既定 6〕件以上集中）・**重複/酷似**（監査ドメインコード重複 / タイトルトークンの Jaccard 類似度 ≥ 0.6）・**ラベル欠損**（priority / sp 未設定。Epic は除外）。

### Step G-2: @owner（PO）連携で優先度・SP を補完

ラベル欠損 Issue（`missing_priority` / `missing_sp`）について `@owner` を **PO として** 呼び出す。@owner は `mcp__github__issue_write` で `sp:` / `priority:` を直接付与できる（`session-sprint-rules.md` §4・ホワイトリストは `sp:` / `priority:` のみ）。基準は SP = `session-sprint-rules.md` §3.1、priority = CP-5 ミッション貢献度（`docs/project-mission.md` の KPI 直結度）。

### Step G-3: 重複・陳腐化の処理（自律実行）

| 判定 | アクション |
|------|-----------|
| **明白な重複**（同一監査コード・酷似タイトルで内容も同一） | 新しい/情報量の少ない方を `mcp__github__issue_write`（state=closed・`duplicate_of` 指定）でクローズし、残す側に集約コメント |
| **陳腐化**（既に実装済み・前提が消滅・他 Issue で解決済み） | 確認のうえクローズ（理由をコメント）。**仕様・実装状況は必ず grep / コード確認してから** 判断する |
| **判断が割れる**（重複に見えて切り口が違う等） | クローズせず、両 Issue に相互リンクコメントのみ |

> 自律クローズの境界: 内容の同一性に確信が持てる場合のみ。少しでも切り口が異なれば残す（消し過ぎより取りこぼしを許容）。

### Step G-4: Epic 統合（自律実行）

`epic_candidates`（同一カテゴリ集中）について追跡 Epic を自動生成する。

- タイトル `[Epic] {カテゴリ}: 改善バックログ統合追跡（{N}件・YYYY-MM-DD）` で `mcp__github__issue_write`（create）
- 本文に子 Issue 一覧（`- [ ] #NNNN タイトル`）と統合の意図を記載。`mcp__github__sub_issue_write` で紐付けられる場合は紐付ける
- **子 Issue はクローズせず残す**（Epic は実装単位でなく追跡単位。実装は消化モードが子 Issue 単位で進める）
- Epic 自体に `type:improvement` ＋（@owner 判断で）`priority:` / `sp:` を付与
- 新規 **マイルストーン** の追加は A-5（要ユーザー確認）。Epic 化では代用しない

### Step G-5: 棚卸しサマリーの記録 + 最優先の受け渡し

1. 結果（処理件数・クローズ数・新規 Epic・優先度補完数）を **作業 Issue にコメント記録**（チャットでの逐次報告は不要・サイレント運用）
2. **最優先 1 件**（priority:high かつ即実装可能）を消化モードへ渡す（そのまま実装するか、`status:waiting-claude` のまま次スロットに委譲）
3. レポートをリポジトリに残す場合は `content/analytics/grooming/YYYY-MM-DD.md`（プロジェクトの保管規約に合わせる）に置き、ファイル変更があれば PR 化

### 整理モードの禁止パターン

```
❌ レポートを見ずに勘でクローズ・Epic 化する（必ず triage_improvements.py のデータに基づく）
❌ 切り口が少しでも違う Issue を「重複」として消す（取りこぼし優先・残す）
❌ priority/sp を @owner を通さずメインが恣意的に決める（PO は @owner）
❌ 子 Issue を Epic 化と同時にクローズする
❌ status:* ラベルを @owner に操作させる（PO 権限境界 §4.1 違反）
```

---

## 消化モード実行フロー（日次・retro-try-handler と連携）

> **トリガー起動時の上書き**: スケジュールトリガー（ルーティン）から起動された場合、起動プロンプト
> 側（下流プロジェクトの運用メモが定義する実行手順等）が指定する **対象スコープ・件数上限・同 priority 内のタイブレーク順**
> は本フローの既定値（status:waiting-claude フィルタ・5 件/回・下記タイブレーク）に **優先** する。
> それ以外（priority ラベルの大小順・サーキットブレーカー等）は本フローに従う。
> タイブレークを上書き対象に含めるのは、1 回 1 件のルーティンでは「小さく確実に減らす」順序が
> 在庫削減に直結し、日次 5 件消化を前提とする本フローの既定と最適解が異なるため（#335）。

```
1. 対象Issue取得:
   クラウド一次経路（repo スコープの gh は 403・L-114）:
     mcp__github__list_issues(owner, repo, state="OPEN", labels=["status:waiting-claude"], perPage=100)
   ローカル環境（gh CLI 到達可能時）の代替:
     gh issue list -R __OWNER__/__REPO__ --state open --limit 1000 \
       --label "status:waiting-claude" --json number,title,labels,milestone,updatedAt
   → type:improvement / type:bug でフィルタし、priority ラベル順（high → medium → なし → low）でソート
     （同 priority 内の順序は下記タイブレークのみで決める。「古い順」は単独では適用しない）
   → **監査バックログ（プロジェクト定義のマイルストーン例: 「監査 P0〜P3」）**: 監査 Issue は
     priority ラベル（P0/P1=high・P2=medium・P3=low）とマイルストーンを起票時に付与済みのため、
     本ソートにそのまま乗る。**同 priority 内のタイブレークは以下の順序で一意に適用する**:
     1. 監査マイルストーン付き Issue を優先し、マイルストーン昇順（P0→P1→P2→P3）でソート
     2. プロジェクト定義の重み付け（例: lessons 高頻度指摘から算出した領域別ウェイト）があれば参照し、
        ウェイトが高い Issue 種別を優先
        （ユーザーが繰り返し重視してきた領域を自律的に先取りするための重み付け）
     3. 上記が同等の場合は作成日時の古い順を適用する

2. 上位 5件（priority:high → priority:medium → priority なし → priority:low → 各群内で上記タイブレーク）を選び、各々:
   - status:in-progress 付与
   - 実装コスト評価 → 小〜中なら実装 → PR → マージ
   - 大規模・曖昧なら設計をIssueコメントに記録し priority 据え置き（着手は次サイクル）
   - ※ in/out 均衡のため上限は 5件/回（refinement の生成ペース 3〜5件/日に対し消化 5件/日で均衡）。
     コスト上限内（時間/トークン）で完走できる範囲に留め、未完分は次サイクルへ持ち越す

3. 放置検出:
   - type:improvement / retro-try で7日以上 updatedAt が古いものを検出
   - サーキットブレーカー: 3サイクル試行しても進まないものは status:blocked + 理由コメント
   - **在庫が 30 件を超えたら整理モードを先に実行する**（「多すぎて選べない」状態の解消）

4. 報告: 消化件数・残数・放置検出結果（**在庫増加率 vs 消化率**を明記）:
   - 当日 created（status:waiting-claude 付与）件数 = in flow
   - 当日 closed もしくは status:waiting-claude 解除 件数 = out flow
   - out < in が3日続く場合は CP-3 衛生アラートとして発見モードにエスカレーション
```

---

## サーキットブレーカー / 安全装置

- 1課題あたり修正サイクル2回超で STOP → Issueコメントに状況記録（session-safety-rules.md）
- 発見モードのコスト上限意識: N 観点並列は重いため発見スロットを限定（プロジェクト定義の頻度）
- 整理モードの自律クローズは「明白な重複・陳腐化」に限定する（判断が割れるものは残す）
- main直接push禁止・PR経由のみ（CP-6 境界外リスト遵守）

## トリガー

| モード | 実行タイミング |
|--------|-------------|
| 発見（完全版） | プロジェクト定義の発見スロット / `/self-improvement-loop` / 「横断レビューして」 |
| 整理（棚卸し） | `type:improvement` が 30 件超滞留した時 / 月次の棚卸しスロット / `/self-improvement-loop --groom` / 「改善Issueを棚卸しして」「改善バックログを整理して」「Epic化して」 |
| 消化（軽量版） | 日次の消化スロット / `/self-improvement-loop --consume` / 「改善Issue消化して」 |

## 関連ファイル

| ファイル | 役割 |
|---------|------|
| `docs/rules/improvement-lane-map.md` | レーン境界の SSOT（振り返り・監査/衛生レーンとの分担） |
| `tools/triage_improvements.py` | 整理モードの集計・分類・重複検出・Epic 候補抽出（副作用なし） |
| `docs/rules/session-sprint-rules.md` | SP 基準（§3）・PO=@owner（§4） |
| `.claude/agents/owner.md` | PO ロール定義（`priority:` / `sp:` ホワイトリスト） |
