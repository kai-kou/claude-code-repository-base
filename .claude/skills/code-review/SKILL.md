---
name: code-review
description: 自前実装のコードレビュースキル（組み込み /code-review の置き換え・FAIR Layer 1 の標準実行手段）。PR 差分または作業ツリー差分を観点別フレッシュ文脈レビュー（並列サブエージェント）→ 敵対的検証 → 指摘報告の 3 段で実行し、PR 文脈では指摘の有無にかかわらず必ず行単位インラインコメントでレビューを残す。「/code-review」「コードレビューして」「差分をレビューして」「PR #N をレビューして」と依頼された時、および PR 作成後の Layer 1 セルフレビュー（pr-review-watcher / self-reviewer から呼び出し）で必ず使用する。組み込み code-review は disable-model-invocation により自律起動不可のため、本スキル（同名 project スコープ・公式仕様で bundled を置換）が対話・自律の両セッションで代替する。
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

**PR 番号指定ありのときは、あわせて PR 本文も取得する**（Step 1 の Spec 忠実性ファインダーが
対象 Issue を解決するために要る。差分だけでは判定材料が揃わない）:

```bash
mcp__github__pull_request_read(method="get", owner="__OWNER__", repo="__REPO__", pullNumber=N)
```

### Step 1: 観点別フレッシュ文脈ファインダー（並列サブエージェント）

**観点ごとに独立のサブエージェント（`general-purpose`、探索中心なら `Explore`）を並列起動** し、
事前文脈なしで差分を「第三者の PR」として読ませる（自己修正盲点 64.5% の回避が目的。
メインセッションが自分でレビューして代替しない）。観点は次の 6 系統を既定とし、
差分の性質に応じて追減してよい:

| 観点 | 焦点 |
|------|------|
| 正確性 | ロジック分岐・境界値・null/空・例外処理・数値/日付整合 |
| セキュリティ | 秘密情報ハードコード・入力検証・インジェクション・権限境界 |
| 簡素化・再利用 | 既存関数での代替・コピペ重複・YAGNI 違反（1 箇所しか使わない抽象化） |
| テスト・検証 | 変更が実行結果で証明可能か・テスト欠落・`bash -n`/`py_compile` |
| ドキュメント整合 | ルール・SKILL.md・README との desync・参照切れ |
| Spec 忠実性 | 対象 Issue / spec の要件の欠落・部分実装・誤解釈、依頼スコープ外の変更混入 |

各ファインダーへの指示テンプレート（`agent-team-summary.md` の出力ルールを先頭に付ける）:

```
この差分を第三者の PR として {観点} の観点でレビューせよ。
指摘は次の 5 項目を必ず埋めた形式で返す（1 指摘 1 ブロック）:
  - ファイル:行番号（差分に現れる行。範囲指摘なら開始-終了行）
  - severity: CRITICAL | WARNING | NIT
  - 欠陥の1文
  - 失敗シナリオ（入力・状態 → 誤動作）
  - 推奨修正（具体的な修正案。コード片可）
失敗シナリオを書けない指摘・スタイル好みは報告しない。指摘ゼロなら「なし」と返す。
```

> `severity` と `推奨修正` は Step 3 のインラインコメント本文テンプレートの必須項目である。
> ここで出力させないと Step 3 でテンプレートを埋める材料が無くなるため、指示から省略しない。

**Spec 忠実性ファインダーだけは追加の入力が要る**。他の 5 観点は差分だけで判定できるが、この観点は
「差分が何を実装すべきだったか」を外から与えないと成立しない。起動前に対象 Issue / spec を確定し、
本文を渡す。解決の順に:

1. Step 0 で取得した **PR 本文の `Closes #N` / `Refs #N`**
2. ブランチ名に含まれる Issue 番号（`claude/...-{N}` 等）
3. コミットメッセージの `Closes #N`（`git log origin/main..HEAD`）

番号が取れたら `mcp__github__issue_read(method="get", ..., issue_number=N)` で本文を取得して渡す。
**どれでも解決できない場合はこの観点をスキップし、スキップした事実と理由を Step 3 の報告に 1 行残す**
（対象不明のまま推測でスコープを判定させない）。作業ツリー差分のレビュー（PR 番号指定なし）でも
同じ手順を使い、取れなければスキップする:

```
次は対象 Issue #{N} の本文（要件と完了条件）である。
---
{Issue 本文}
---
この差分を第三者の PR として **Spec 忠実性** の観点でレビューせよ。判定するのは次の 3 点だけである:
  (a) 要件の欠落・部分実装 — 完了条件のうち差分が満たしていないものはどれか
  (b) 誤解釈 — 要件が求めたのとは違うものを実装していないか
  (c) スコープ逸脱 — 依頼に含まれない変更（drive-by リファクタ・整形・依存追加）が混入していないか
コードの品質・バグ・命名は **他の観点の担当なので指摘しない**（二重指摘の防止）。
指摘形式・失敗シナリオの要求・指摘ゼロ時の返し方は上記テンプレートと同じ。
```

> **なぜ独立した観点にするか**: 「対象 Issue が求めたものを実装したか」は、他の 5 観点（差分そのものの
> 良し悪し）とは判断材料が違う。同じサブエージェントに両方を見せると、コード品質の判断が Spec 判定を
> 汚染する（きれいに書けている差分を「要件を満たしている」と読み替えてしまう）。**フレッシュ文脈で
> 分離するのが目的**なので、既存観点の説明文に 1 行足す形に潰さない。
>
> `docs/rules/self-review-checklist.md` の Done Criteria チェックとは **段階が違う**（あちらは PR 作成前・
> 同一コンテキストでの目視確認、こちらは PR 作成後・独立フレッシュ文脈での検証）。重複ではなく多層防御。

### Step 2: 敵対的検証（false positive の排除）

ファインダーの指摘を **そのまま報告しない**。指摘ごとに反証担当サブエージェントへ
「この指摘を反証せよ（既存のガードで防がれていないか・実際に到達可能か）」を渡し、
反証に耐えた指摘のみ **CONFIRMED** として残す（反証しきれないが疑いが残るものは
**PLAUSIBLE** と明記）。指摘が少数（3 件以下）ならメインセッションが自分で反証確認してもよい。

### Step 3: 報告・対応（PR 文脈では **インラインコメント必須**）

| 文脈 | 報告先 |
|------|--------|
| **自律 PR フロー**（Layer 1・`pr-review-watcher` / `self-reviewer` からの呼び出し） | **必ず Step 3-A の手順で GitHub のレビューを 1 件投稿する**（指摘ゼロでも投稿する）。チャットには報告しない（L-102 サイレント） |
| **対話セッションでユーザーが PR を指定して依頼**（`/code-review {PR番号}`・「PR #N をレビューして」） | **Step 3-A で投稿した上で**、チャットにアウトカム 1 行（投稿件数・重大度内訳・PR リンク）を返す。ユーザー自身が依頼したレビューの結果報告は L-102 の対象外 |
| PR が存在しない作業ツリー差分レビュー | チャットに重大度順で報告。`ReportFindings` ツールが利用可能な環境ではそちらで報告する（投稿先が無いためインライン投稿は行わない） |

- 修正適用（`--fix` 相当）を求められたら、CONFIRMED 指摘の修正を作業ツリーへ適用（自律フローでは修正コミット）する
- 修正サイクルが 2 回を超えたらサーキットブレーカー（A-4）で STOP しユーザー報告
- diff ≥300 行 / `type:security` / `type:breaking-change` は Layer 2（`discussion_review_trigger.py`）も起動する（`ai-reviewer-strategy.md`）

#### Step 3-A: インラインレビュー投稿手順（PR 文脈で必ず実行・#461）

> **なぜ必須か**: 後から PR を振り返ったときに「どの行にどんな指摘があり、どう決着したか」を読み取れるようにするため。
> 集約コメントやチャット報告では、指摘と対応（Resolve 状態）の紐付けが失われる。**指摘ゼロでも投稿する**
> （投稿しないと「レビュー実施・0 件」と「レビュー未実施」を後から区別できない）。

**0. 既存 pending review の破棄（二重作成防止）**

```
mcp__github__get_me()                                                    # login を取得
mcp__github__pull_request_read(method="get_reviews", owner, repo, pullNumber=N)
  → 自分の login かつ state="PENDING" の review があれば
    mcp__github__pull_request_review_write(method="delete_pending", owner, repo, pullNumber=N)
```

前セッションが `submit_pending` 前に中断していると、この破棄を省いた `create` は失敗する（pending は 1 ユーザー 1 PR に 1 件）。

**1. 対象コミットと diff ハンク範囲の確定**

```
mcp__github__pull_request_read(method="get", owner, repo, pullNumber=N)       → head.sha を控える
mcp__github__pull_request_read(method="get_diff", owner, repo, pullNumber=N)  → `@@ -a,b +c,d @@` をパース
```

ファイルごとに「RIGHT 側で有効な行レンジ」「LEFT 側で有効な行レンジ」の表を作る。**この表が投稿可否判定の正本**。

**2. pending review の作成（`event` は渡さない）**

```
mcp__github__pull_request_review_write(method="create", owner, repo, pullNumber=N, commitID="{head.sha}")
```

`event` を渡すと即 submit されコメントを積めない。`commitID` は force push 後の取り違えを防ぐため必ず指定する。

**3. 指摘ごとにインラインコメントを積む（CONFIRMED / PLAUSIBLE とも全件）**

```
# ケース A: 指摘行が RIGHT 側ハンク内（通常）
mcp__github__add_comment_to_pending_review(owner, repo, pullNumber=N, path="{file}",
  body="{テンプレート}", subjectType="LINE", side="RIGHT", line={行})
# ケース B: 削除行への指摘 → side="LEFT"（line は旧ファイルの行番号）
# ケース C: 複数行 → startLine={開始} + startSide={開始行の side} + line={終了} + side={終了行の side}
# ケース D: ハンク外・リネームのみ・ファイル削除 → subjectType="FILE"（line / side は付けない）
```

本文テンプレート（**全項目必須**。1 行目だけで重大度・確度・観点が読めるようにする）:

```markdown
**🔴 CRITICAL** ・ **CONFIRMED** ・ 観点: 正確性
<!-- severity は 🔴 CRITICAL / 🟡 WARNING / ⚪ NIT、確度は CONFIRMED / PLAUSIBLE -->

{欠陥を1文で}

**失敗シナリオ**: {入力・状態} → {誤動作}

**推奨修正**: {具体的な修正案}
```

- ケース D では本文冒頭に `元は {file}:{line}（diff 範囲外のためファイル単位コメントに切替）` を明記し、**指摘を握りつぶさない**。
- 同一ラウンド内で複数のファインダーが同じ `path:line` を報告した場合は、投稿前に統合する（バッチ内 dedup）。
  **既存 PR コメントとの行番号照合による重複スキップはしない**（修正コミットで行番号がシフトし、同じ行に生まれた
  別の新規欠陥を「既出」と誤判定して握りつぶすため・L-077 と矛盾する）。

**4. レビューを確定する（`event="COMMENT"` 固定）**

```
mcp__github__pull_request_review_write(method="submit_pending", owner, repo, pullNumber=N,
  event="COMMENT", body="{サマリー}")
```

- **`APPROVE` は使わない**（PR 著者は自分の PR を承認できず必ず失敗する）。
- **`REQUEST_CHANGES` も使わない**（`pull_request_review_write` に dismiss / 更新の method が無く、自分で解除できない）。
  critical の強制力は本スキルの「critical は修正コミット必須」で担保し、レビューイベント種別に依存させない。
- サマリー本文は **実行証跡 + 目次** に限定し、技術詳細はインライン側に置く（二重記載は修正時に食い違う）:

```markdown
## Layer 1 セルフレビュー結果（{YYYY-MM-DD HH:MM JST}）

観点: 正確性 / セキュリティ / 簡素化・再利用 / テスト・検証 / ドキュメント整合 / Spec 忠実性（{実施数} 系統実施）
{未実施があれば「未実施: Spec 忠実性（理由: 対象 Issue を解決できず）」の 1 行を必ず置く}

- CONFIRMED: {件数}件（🔴{n} 🟡{n} ⚪{n}）→ 各インラインコメント参照
- PLAUSIBLE: {件数}件
```

**実施数は固定値を書かない**。Step 1 で観点を追減した場合・Spec 忠実性を対象 Issue 未解決でスキップした
場合は、その実数と未実施の理由を反映させる（実施していない観点を実施したと書くのは L-113 の捏造にあたる）。

**指摘ゼロ件のとき** は 3 をスキップし、`create` → `submit_pending(event="COMMENT")` だけを実行して
`観点 {実施数} 系統実施 → 敵対的検証 → 指摘 0 件` と本文に明記する。**追加の issue コメントは打たない**（二重記録の回避）。
submit 済みレビューの body は編集できないため、再レビューは新しいレビューとして投稿する。

**5. スレッド ID を取得して既存フローへ合流**

```
mcp__github__pull_request_read(method="get_review_comments", owner, repo, pullNumber=N)
```

以降は `pr-review-flow.md` 既存の「返信 → Resolve」フローに乗せる。返信は **必ず該当スレッドへの返信** で行う
（新規コメントに分離すると指摘と結論の紐付けが切れる）:

```
✅ 対応しました。{修正概要}（{commit_sha}）
⏭️ スキップします。理由: {理由}
```

PLAUSIBLE は確度が低いので `⏭️ スキップします。理由: 確度低（PLAUSIBLE）` で閉じてよい。**未返信のまま放置しない**。

#### Step 3-B: 投稿に失敗したときのフォールバック（サイレント放棄は禁止）

```
add_comment_to_pending_review が失敗
  ├─ 422（line がハンク外）→ 同ファイルへ subjectType="FILE" で 1 回だけ再投稿
  ├─ FILE 再投稿でも失敗 → 失敗した指摘を **まとめて** 1 回だけ
  │    mcp__github__add_issue_comment(owner, repo, issue_number=N, body="{集約した指摘一覧}")
  │    で PR コメントとして記録する
  │    ⚠️ mcp__github__update_pull_request(body=...) は使わない（全文置換で PR 説明文を破壊する）
  └─ add_issue_comment も失敗 → submit_pending の body に未記録指摘を集約し、
       `problem-investigation-protocol.md` の 5 ステップで原因を調査する
```

`create` / `submit_pending` 自体が失敗した場合も放置しない（次セッションが Step 0 の PENDING 検出で回収する）。

## 注意（再発防止）

- 本スキルの frontmatter に `disable-model-invocation` を **追加しない**（追加すると自律起動が再び不能になり本スキルの存在意義が消える）
- PR 文脈で **インライン投稿を省略しない**（#461）。「指摘が軽微だから」「ゼロ件だから」「チャットで報告したから」は
  いずれもスキップ理由にならない。投稿しない唯一のケースは「PR が存在しない作業ツリー差分レビュー」だけ
- `event="APPROVE"` / `event="REQUEST_CHANGES"` を指定しない（前者は自己 PR で必ず失敗、後者は自分で解除できない）
- 組み込み側の仕様がさらに変わっても、project スコープ同名スキルの置換が効く限り本スキルが優先される。挙動異常時は `claude-code-spec-sync` レーンで公式 changelog を確認する（L-119）
