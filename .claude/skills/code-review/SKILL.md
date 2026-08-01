---
name: code-review
description: 自前実装のコードレビュースキル（組み込み /code-review の置き換え・FAIR Layer 1 の標準実行手段）。PR 差分または作業ツリー差分を観点別フレッシュ文脈レビュー（並列サブエージェント）→ 敵対的検証 → 指摘報告の 3 段で実行する。「/code-review」「コードレビューして」「差分をレビューして」「PR #N をレビューして」と依頼された時、および PR 作成後の Layer 1 セルフレビュー（pr-review-watcher / self-reviewer から呼び出し）で必ず使用する。組み込み code-review は disable-model-invocation により自律起動不可のため、本スキル（同名 project スコープ・公式仕様で bundled を置換）が対話・自律の両セッションで代替する。
effort: high
model: inherit
---

# 自前 code-review スキル（組み込み /code-review 置き換え）

組み込み `code-review` スキルは v2.1.215 で自動実行が廃止され（`disable-model-invocation`・v2.1.216 実機確認）、
Claude が Skill ツール経由で自律起動できなくなった。本スキルは **project スコープの同名スキルが
bundled スキルを置換する公式仕様**（[skills ドキュメント](https://code.claude.com/docs/en/skills.md)
「A skill at any of these levels also overrides a bundled skill with the same name」）を利用した
自前実装であり、`disable-model-invocation` を付けないことで **対話（`/code-review` 手打ち）と
自律セッション（Skill ツール）の両方から起動できる**。FAIR 構成の SSOT は
`docs/rules/ai-reviewer-strategy.md`。

## トリガー条件

- `/code-review`（引数: PR 番号 or 省略で作業ツリー差分）・「コードレビューして」等の依頼時
- **PR 作成後の Layer 1 セルフレビュー**（全 PR 必須・`pr-review-watcher` / `self-reviewer` Step 4 から呼び出し）
- 修正コミット後の再レビュー時（`pr-review-flow.md` 修正サイクル）

## 実行フロー（find → verify → report）

### Step 0: レビュー対象差分の確定

```bash
# PR 番号指定あり（クラウド一次経路 = MCP・L-114）
mcp__github__pull_request_read(method="get_diff", owner="__OWNER__", repo="__REPO__", pullNumber=N)
# 指定なし = 現在ブランチの差分（未コミット含む）
git fetch origin +main:refs/remotes/origin/main && git diff origin/main...HEAD && git diff HEAD
```

差分ゼロなら「レビュー対象なし」を報告して終了する（空レビューを捏造しない・L-113）。

### Step 1: 観点別フレッシュ文脈ファインダー（並列サブエージェント）

**観点ごとに独立のサブエージェント（`general-purpose`、探索中心なら `Explore`）を並列起動** し、
事前文脈なしで差分を「第三者の PR」として読ませる（自己修正盲点 64.5% の回避が目的。
メインセッションが自分でレビューして代替しない）。観点は次の 5 系統を既定とし、
差分の性質に応じて追減してよい:

| 観点 | 焦点 |
|------|------|
| 正確性 | ロジック分岐・境界値・null/空・例外処理・数値/日付整合 |
| セキュリティ | 秘密情報ハードコード・入力検証・インジェクション・権限境界 |
| 簡素化・再利用 | 既存関数での代替・コピペ重複・YAGNI 違反（1 箇所しか使わない抽象化） |
| テスト・検証 | 変更が実行結果で証明可能か・テスト欠落・`bash -n`/`py_compile` |
| ドキュメント整合 | ルール・SKILL.md・README との desync・参照切れ |

各ファインダーへの指示テンプレート（`agent-team-summary.md` の出力ルールを先頭に付ける）:

```
この差分を第三者の PR として {観点} の観点でレビューせよ。
指摘は「ファイル:行番号 / 欠陥の1文 / 具体的な失敗シナリオ（入力・状態 → 誤動作）」の形式。
失敗シナリオを書けない指摘・スタイル好みは報告しない。指摘ゼロなら「なし」と返す。
```

### Step 2: 敵対的検証（false positive の排除）

ファインダーの指摘を **そのまま報告しない**。指摘ごとに反証担当サブエージェントへ
「この指摘を反証せよ（既存のガードで防がれていないか・実際に到達可能か）」を渡し、
反証に耐えた指摘のみ **CONFIRMED** として残す（反証しきれないが疑いが残るものは
**PLAUSIBLE** と明記）。指摘が少数（3 件以下）ならメインセッションが自分で反証確認してもよい。

### Step 3: 報告・対応

| 文脈 | 報告先 |
|------|--------|
| 対話セッション（ユーザーが `/code-review` を起動） | チャットに重大度順で報告。`ReportFindings` ツールが利用可能な環境ではそちらで報告する |
| 自律 PR フロー（Layer 1） | **PR スレッドのみ** に記録（チャット報告しない・L-102 サイレント）。critical は修正コミット必須、それ以外は修正 or スキップ理由を返信して Resolve |

- 修正適用（`--fix` 相当）を求められたら、CONFIRMED 指摘の修正を作業ツリーへ適用（自律フローでは修正コミット）する
- 修正サイクルが 2 回を超えたらサーキットブレーカー（A-4）で STOP しユーザー報告
- diff ≥300 行 / `type:security` / `type:breaking-change` は Layer 2（`discussion_review_trigger.py`）も起動する（`ai-reviewer-strategy.md`）

## 注意（再発防止）

- 本スキルの frontmatter に `disable-model-invocation` を **追加しない**（追加すると自律起動が再び不能になり本スキルの存在意義が消える）
- 組み込み側の仕様がさらに変わっても、project スコープ同名スキルの置換が効く限り本スキルが優先される。挙動異常時は `claude-code-spec-sync` レーンで公式 changelog を確認する（L-119）
