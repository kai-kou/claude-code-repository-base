# PRレビューフロー（サマリー版）

> 完全版は `docs/rules/pr-review-flow.md`（マージコンフリクト解決・force push 後の再レビュー・監視方式・パイプライン別チェックリスト）。
> 実行手順そのものは `pr-review-watcher` スキルが持つ。本ファイルは **判断基準と不変の境界** だけを常駐させる。

## フロー概要

```
実装 → セルフレビュー（self-reviewer）→ PR 作成 → Slack 通知
  → Layer 0 機械ゲート + Layer 1 観点別フレッシュ文脈セルフレビュー（主軸・全 PR 必須・自己実行）
  → 指摘対応（修正コミット or スキップ + 返信 + Resolve）→ Layer 0+1 通過で自動マージ（squash）
  → **公開反映（publish-sync・マージした同一セッションで完遂）** → Slack 完了通知
```

- **🟢 恒久承認**: 実装完了したら確認なしで PR まで進める（SSOT: `CLAUDE.md`「PR 作成の完全自律化」）。「PR 作成してよいですか？」は禁止。
- **🔴 外部 AI レビュアーは廃止**: Copilot / Gemini へのレビュー依頼・催促は行わない。レビューは **Layer 1 セルフレビューで完結** させ、外部応答を待たない（SSOT: `ai-reviewer-strategy.md`）。
- **Layer 1 の標準実行手段は `Skill(code-review)`**（`.claude/skills/code-review/` が組み込みを置換・自律起動可）。

## PR 作成時の必須事項（コマンド仕様は各ツールの description に従う）

1. `mcp__github__create_pull_request`（`head`={作業ブランチ} / `base`=main）。本文に **`Session-Id: $CLAUDE_CODE_SESSION_ID`**・`Sprint Goal:` 1 行・`sp:N` を必ず含める（`--mine` 所有判定と done_sp 計測の前提）
2. **PR 存在確認（必須・L-050）**: `mcp__github__list_pull_requests` で `head` を指定して実在を確認する（作成の成否をレスポンスだけで判断しない）
3. Slack 通知: `python3 tools/slack_notify.py pr --pr-url ... --pr-title "[PR作成] ..." --branch ...`
4. **Layer 1 セルフレビュー**: `Skill(code-review)` を必ず実行 → 指摘を PR にインライン記録 or スレッド返信
5. （任意）`mcp__github__subscribe_pr_activity` + `tools/pr_review_heartbeat.sh` で CI / 人手コメントを監視

> ローカル実行時は `gh pr create --head {branch} --base main -R {owner}/{repo}` でもよい。クラウドでは MCP が一次経路。

## レビュー監視と自動マージ

| タイミング | アクション |
|---------|-----------|
| PR 作成直後 | Layer 1 セルフレビュー → 指摘対応（修正コミット or スキップ + 返信 + Resolve） |
| Layer 0+1 通過後 | `mcp__github__merge_pull_request`（`merge_method="squash"`）で即マージ |
| **マージ直後** | **公開リポジトリへ反映（`publish-sync`）**。`post-merge-publish-check.sh` がドリフトを判定して指示を注入する。反映できないセッション（`add_repo` 不在・L-117）は `[publish-sync]` Issue に記録して終える（沈黙禁止・#449）→ Slack 完了通知 |
| 任意 | CI 失敗・人手コメントがあれば対応してからマージ |

サーキットブレーカー: 修正サイクル 2 回超で STOP → ユーザー報告（A-4）。

**マージ後のチャット完了報告は `completion-report-rules.md`（SSOT）に従う**: 「ご依頼（初回指示の再掲）→ アウトカム」を冒頭に置き、マージ方法・レビュー往復・指摘件数を主役にしない。「PR #N をマージしました」だけで終わらせない。

## 指摘対応ルール

- **サイレント原則（L-102）**: AI レビュー指摘対応は **ユーザーに報告しない**。記録は PR スレッド返信・Resolve・Issue コメントのみ。チャット逐次報告・Slack `@mention`・完了報告アウトカムへの混入は禁止。例外は A-1〜A-6 のみ
- **`<github-webhook-activity>` は抑制対象ではない（#61）**: これは **ハーネスが配信する入力**（購読中は必ず履歴に出る作業キュー）であり、L-102 が禁じる「assistant のナレーション」とは別物
- 対応した場合: 「対応しました。{修正概要}（{commit_sha}）」を返信してから Resolve
- スキップした場合: 「スキップします。理由: {理由}」を返信してから Resolve（製品名・API 仕様は公式ドキュメントで確認してから記録する）

## セッション復帰（PR 放置検出）

```bash
python3 tools/check_pending_pr_reviews.py --mine --actionable-only --json   # ① 自 PR を最優先で回収
python3 tools/check_pending_pr_reviews.py --actionable-only --json          # ② 他保護込みの全体ビュー（孤児 PR 救済）
```

`needs_prompt` → Layer 1 セルフレビュー実行 → 指摘解消 → 即マージ / `needs_response` → 指摘対応（CI 失敗・人手コメント）/ `awaiting_review` → 作成セッションが実行中（待機）。

**公開反映の回収も復帰時の責務（#449）**: `python3 tools/check_publish_drift.py --quiet` が 1（ドリフトあり）/ 2（判定不能）なら、`publish-sync` スキルで反映まで完遂する。`[publish-sync]` の open Issue は「前のセッションが反映できずに残した積み残し」なので最優先で消化してクローズする。

- **自スコープ優先（#47）**: `--mine` は PR 本文の `Session-Id` トレーラーで自 PR を決定論的に識別する。時間ベースの除外を受けないため、圧縮・再起動後も確実に回収できる
- **他セッション対応中の PR には介入しない（CP-4・L-109）**: 直近 10 分以内に人間側アクティビティがある PR は `active_session: true` として `--actionable-only` から自動除外される。**出力に現れない PR には触れない**（催促・指摘対応・マージ・subscribe をしない。`--include-active` での強制取得も禁止）
