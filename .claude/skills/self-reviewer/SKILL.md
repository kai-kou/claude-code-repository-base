---
name: self-reviewer
description: PR作成前にセルフレビューを実行し、AIレビュアーが指摘しそうな問題を事前に検出・修正する。PR作成直前の最終チェックとして、「セルフレビューして」「PR前にチェックして」と依頼された時に使用する。PR 作成前の事前チェック（Step 0-3）が主担当で、PR 作成後の Layer 1 観点別フレッシュ文脈レビューは自前 code-review スキル（.claude/skills/code-review/・組み込みを置換・自律起動可）を Skill(code-review) で呼び出して実行する。
effort: high
---

# PR 作成前セルフレビュースキル（汎用）

PR 作成前に問題を自分で検出・修正してレビュー往復を減らす。`pre-pr-create-check.sh` フックが
`tools/self_review_check.py` を呼ぶため、Error が残ると PR 作成自体がブロックされる。

> **🔴 レビューは Claude 自身のセルフレビューで完結する**: 外部 AI レビュアー（Copilot / Gemini）への
> 依頼は **行わない**。組み込み `/code-review` は disable-model-invocation で自律起動不可のため、
> **自前 `code-review` スキル（`.claude/skills/code-review/`・同名 project スキルが bundled を置換・
> 自律起動可）が Layer 1 の標準実行手段**（#275 → #280）。本スキルは PR 作成前の事前チェック
> （Step 0-3）を担い、Step 4 で自前 `code-review` スキルを呼び出す。
> 構成の SSOT は `docs/rules/ai-reviewer-strategy.md`。

## トリガー条件

- PR 作成直前の最終チェック時
- 「セルフレビューして」「PR 前にチェックして」「レビューコスト下げたい」等の依頼時

## 実行フロー

### Step 0: 機械チェック（必須・最初に実行）

```bash
python3 tools/self_review_check.py

# .md を新規作成・修正した場合は CJK 半角スペースを必ず自動整形してから PR を作る
# （目視では大規模ドキュメントで必ず見落とし、AI レビュアーに同種指摘される・再発防止）
python3 tools/check_cjk_markdown.py --fix --changed
```

- Error（マージコンフリクト痕跡・巨大ファイル等）が残る限り PR 作成は禁止（フックでもブロック）
- Warning は修正するか、PR 説明文「設計意図・既知の警告」に理由を記載する
- **CJK 半角スペース Warning が出たら必ず `check_cjk_markdown.py --fix` で整形してから PR**
  （変更 .md がある PR では `--fix --changed` の実行を必須化する）
- プロジェクト固有のチェック項目は `docs/rules/self-review-checklist.md` に追記し、
  `self_review_check.py` に検査関数を足して機械化する（同一 PR でシートとランナーを更新）

### Step 1: 差分スコープの確認

```bash
git diff main...HEAD --name-only
```

- **タスク外のファイルが混入していないか**（「ついで」の変更は別 PR / 別 Issue に分離）
- 自動生成ファイル・state ファイルが意図せず含まれていないか
- 削除・リネームが意図どおりか
- 対象 Issue の Done Criteria（Issue 本文または最初のコミットメッセージのいずれかに記載）を diff が満たすか照合する。どちらにも未記載の場合はスキップし、その旨を 1 行記録する

### Step 2: 変更内容のセルフレビュー（観点別）

| 観点 | 確認項目 |
|------|---------|
| **正確性** | ロジックの分岐網羅・境界値・null/空配列・例外処理。数値・単位・日付の整合 |
| **再利用 / 重複** | 既存関数・ユーティリティで代替できないか。コピペ重複がないか |
| **命名 / 可読性** | 周辺コードの命名・コメント密度・イディオムに合わせているか |
| **後方互換** | 既存の呼び出し元・スキーマ・API を壊していないか |
| **セキュリティ** | 秘密情報のハードコードがないか。入力バリデーション・コマンドインジェクション対策 |
| **エラー処理** | 例外を握りつぶしていないか（CP-6: 障害は調査して自律修正、握りつぶさない） |
| **テスト / 検証** | 変更を客観的な実行結果で証明できるか（`bash -n` / `py_compile` / テスト実行） |
| **スコープ超過（設計）** | リクエスト対象の実装内部で、1 箇所しか使わない汎用インターフェース・抽象化が追加されていないか（YAGNI） |
| **ドキュメント整合** | ルール・SKILL.md・README と実装が乖離していないか（desync 防止） |

### Step 3: コミット / ブランチ衛生

- 未コミット・未追跡ファイルがないこと（`git status` が clean）
- 未 push コミットがないこと（`git push -u origin <branch>` 済み）
- `main`/`master` 直接 push になっていないこと
- コミットメッセージが「何をしたか」を簡潔に表していること

### Step 4: 観点別フレッシュ文脈セルフレビュー（Layer 1・必須）

PR 作成後に **自前 `code-review` スキルを `Skill(code-review)` で必ず実行** する（Layer 1・全 PR 必須）。
観点別ファインダー（並列サブエージェント）→ 敵対的検証 → 報告の 3 段で、差分を「第三者の PR」として
読み直し自己修正盲点（64.5%）を回避する。**指摘は確度を問わず全件 PR の行単位インラインコメントで記録し、
指摘ゼロでも `event="COMMENT"` のレビューを 1 件投稿する**（#461。手順・本文テンプレートは
`.claude/skills/code-review/SKILL.md` Step 3-A が SSOT）。対応結論は同一スレッドへの返信 + Resolve で残し、
修正コミット or スキップ理由の記録で解消してから自動マージする。

> `.claude/skills/code-review/` は組み込み `/code-review`（disable-model-invocation で自律起動不可）を
> 同名 project スキルとして置換した自前実装（#275 → #280）。対話セッションの手打ちも同スキルに解決される。
> 万一 `Skill(code-review)` が disable-model-invocation エラーを返す場合（bundled 側に解決が倒れた場合）のみ、
> 旧手段としてサブエージェント（`general-purpose`/`Explore`）に Step 2 の観点表を渡す直接レビューへフォールバックする。

diff ≥300行 / `type:security` / `type:breaking-change` の PR は Layer 2（`discussion_review_trigger.py`）も起動する。
critical 指摘は修正必須（自動ゲート扱い）。**外部 AI レビュアー（Copilot / Gemini）への依頼はしない。**

## 出力

```
## セルフレビュー結果
- 機械チェック: PASS / FAIL（Error N 件）
- 差分スコープ: タスク内 / 混入あり（{ファイル}）
- 検出した問題: {観点}: {内容} → 修正済み / PR 説明に記載
- ブランチ衛生: clean / 要対応
→ PR 作成可否: GO / 修正してから再チェック
```

> プロジェクト固有のセルフレビュー項目（生成物のスキーマ検証・性能閾値・ドメイン品質ゲート等）は
> `docs/rules/self-review-checklist.md` に追記して育てる。
