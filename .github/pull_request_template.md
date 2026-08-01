<!-- session-sprint-rules.md §2/§5・#45: スプリント計測のため「スプリントメタ」を必ず記入する -->

## 概要

{何をしたか・なぜ（Closes #N）}

## Sprint Goal

{1 文。Dynamic 補正の有無と理由を 1 句添える。例: 対象 #N を完了。要リサーチのため Dynamic +2}

## スプリントメタ（必須・削除しない）

- Session-Id: {`echo $CLAUDE_CODE_SESSION_ID` の値。**二重用途で必須**: ①セッション ↔ PR 突合（メトリクス・§5）②`check_pending_pr_reviews.py --mine` の自セッション所有判定（再起動・圧縮後も自 PR をマージまで責任継続・#47）。記載漏れは時間窓フォールバックで精度低下し所有特定も不能になる}
- sp: {1 / 2 / 3 / 5 / 8。`docs/project-mission.md` の工程別標準値 + Dynamic 補正で算定。マージ前に Issue か PR に `sp:N` ラベルを付与}

## セルフレビュー

- [ ] `python3 tools/check_cjk_markdown.py --fix --changed` を実行した
- [ ] `sp:N` ラベルを付与した（done_sp 計測のため・§7）
- [ ] `Session-Id:` を記載した（セッション別ベロシティ計測 + `--mine` 自セッション所有判定のため・#47）
