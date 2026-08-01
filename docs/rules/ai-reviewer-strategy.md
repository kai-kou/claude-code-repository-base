# AIレビュアー戦略（FAIR 構成 SSOT）

> `pr-review-flow.md` / `pr-review-flow-summary.md` / 各パイプライン SKILL.md のレビュー呼び出しは本方針に従う。
> 意思決定経緯は開発リポジトリの提案記録として保持している。

> **🔴 外部 AI レビュアーへの依頼は廃止（飼い主決定・本タスク）**: **Copilot へのレビュー依頼（`mcp__github__request_copilot_review` / `gh pr edit --add-reviewer @copilot`）は行わない。** Gemini も 2026-07-17 で廃止済み。レビューは **Claude 自身が実行するセルフレビュー（Layer 1）を主軸** とし、外部レビュアーの応答を待たない。外部従量レビューに依存しないことで 25 分待ちを解消し、コストをサブスク枠内に収める。

> **🔴 `/code-review` は自前スキルで置き換え済み（2026-07-21・#275 → #280）**: 組み込み `code-review` スキルは
> v2.1.215 で自動実行が廃止され（公式 changelog「Claude no longer runs the `/verify` and `/code-review`
> skills on its own」・v2.1.216 時点で撤回なし）、Claude が Skill ツール経由で自律起動できなくなった。対策として **project スコープの
> 同名スキル `.claude/skills/code-review/`（自前実装・`disable-model-invocation` なし）が bundled を置換する**
> （公式仕様: 「A skill at any of these levels also overrides a bundled skill with the same name. For example,
> a `code-review` skill in your project's `.claude/skills/` replaces the bundled `/code-review`」）。
> これにより **対話（`/code-review` 手打ち）・自律セッション（`Skill(code-review)`）の両方から起動可能** で、
> **Layer 1 の標準実行手段は自前 `code-review` スキル**（観点別フレッシュ文脈レビュー → 敵対的検証 → 報告）とする。
> 万一スキル解決が bundled 側に倒れて自律起動エラーが再発した場合のみ、旧手段（`self-reviewer` Step 2 の
> サブエージェント観点別レビューを直接実行）へフォールバックする（L-119）。

## FAIR（Fresh-context Adversarial In-session Review）

| Layer | 役割 | コスト | ステータス |
|-------|------|--------|-----------|
| **Layer 0 機械ゲート** | `self_review_check.py`（`scan_dangerous_patterns.py` 含む）/ `check_cjk_markdown.py` / lint / test | ゼロ | ✅ 全 PR 必須 |
| **Layer 1 CCR セルフレビュー（主軸）** | **自前 `code-review` スキル（`.claude/skills/code-review/`・組み込みを置換・自律起動可）を `Skill(code-review)` で必ず実行**。観点別フレッシュ文脈ファインダー（並列サブエージェント）→ 敵対的検証 → 報告の 3 段で、差分を「第三者の PR」として読み直し自己修正盲点 64.5% を回避。指摘は PR インラインコメント or スレッド返信で記録。対話セッションの `/code-review` 手打ちも同じ自前スキルに解決される | ゼロ（サブスク枠内） | ✅ **全 PR 必須（依頼ではなく自己実行）** |
| **Layer 2 敵対的多観点議論** | **`discussion-review` スキル（ネイティブ Agent Teams・既定）** + `discussion_specs/code_review.json`（4 観点・敵対 rebuttal）。`tools/discussion_review_trigger.py` が要否判定と実行プラン出力（`--legacy` で旧 claude -p 経路へフォールバック） | ゼロ | ✅ 条件付き必須（diff ≥300行 または `type:security`/`type:breaking-change` ラベル時）|
| **Layer 3 外部独立レビュー** | `anthropics/claude-code-security-review` Action / `/ultrareview` 等。**Copilot・Gemini は使わない。** 高リスク差分のみ任意で起動（手動・非ブロッキング） | 従量（高リスク時のみ） | ⚪ 任意（高リスク差分のみ・外部 AI レビュアー依頼は除く） |
| ~~Copilot~~ | レビュー依頼を廃止（本タスク） | — | ❌ 不使用 |
| ~~Gemini Code Assist~~ | 2026-07-17 廃止済み | — | ❌ 停止 |

> **Layer 0+1 通過で即マージ可**（Layer 2 は条件付き必須）。外部 AI レビュアー（Copilot/Gemini）の応答待ちは存在しない。
> 同一 Claude モデルの系統的誤り（~60%）は Layer 2 の敵対的議論と、高リスク差分での Layer 3（security-review Action 等）で吸収する。

### Layer 3 起動判断の機械シグナル（#53）

`tools/detect_pr_diff_type.py`（既存の code/data 判定と同一ツール。Layer 2 の起動判断自体は
`tools/discussion_review_trigger.py` が独自に行う別ロジックであり、本ツールを呼び出すわけではない）は
`high_risk` フィールドで Layer 3 起動検討シグナルを返す。
認証/秘密情報関連パス・公開API/スキーマ/DB関連パス・フック/CI/権限境界（`.claude/hooks/` / `.github/workflows/` / `.claude/settings.json` / `.mcp.json`）の変更・差分行数（500行以上）/ファイル数（20件以上）のいずれかで `true` になる。
マージをブロックしない任意シグナルであり、`--risk-only` で `true`/`false` のみ取得できる。

```bash
python3 tools/detect_pr_diff_type.py --risk-only   # true/false のみ
```

`high_risk=true` を検出したら、Layer 3（`claude-code-security-review` Action 等）の手動起動を検討する。

## Layer 2 自動トリガー（Issue #97）

`tools/discussion_review_trigger.py --pr {PR番号}` を PR 作成後に呼び出すと、
以下の条件を満たす PR に対して自動的に Layer 2 レビューを起動する。

| 条件 | 閾値 |
|------|------|
| 差分行数（追加 + 削除） | ≥ 300 行 |
| PR ラベル | `type:security` または `type:breaking-change` |

条件を満たさない PR は Layer 0 + Layer 1（自前 `code-review` スキル）のみで対応する（Layer 2 スキップ）。
Layer 2 失敗時は stderr に警告を出力し、Layer 0+1 で継続する（フォールバック禁止でなくサイレント禁止）。

## マージ可否の判定（外部レビュアー非依存）

- **Layer 0（機械ゲート）+ Layer 1（セルフレビュー）の通過で即マージ可。** 外部 AI レビュアーの応答を待たない（25 分タイムアウトの待機は発生しない）。
- Layer 1 は「依頼して待つ」ものではなく、PR 作成と同一セッションで Claude 自身が自前 `code-review` スキル（観点別フレッシュ文脈レビュー）を実行して完結させる。検出された指摘は修正コミット or スキップ理由を記録してから自動マージする。
- 条件付きで Layer 2（敵対的議論）が必要な PR は、Layer 2 の verdict も解消してからマージする。

## 関連

- [#97] Layer 2 定常化 / [#2485] Gemini 廃止に伴う代替設計 / [#49] Claude 単独 FAIR への移行決定 / [Copilot 依頼廃止・`/code-review` セルフレビュー必須化タスク] / [#275] `/code-review` disable-model-invocation 対応 / [#280] 自前 `code-review` スキル新設（bundled 置換・Layer 1 標準実行手段）
- `.claude/skills/code-review/SKILL.md`（Layer 1 実行主体・本方針の実装）
- `tools/discussion_review_trigger.py`（Layer 2 議論スペック `discussion_specs/code_review.json` は開発リポジトリ側で管理・下流では `--spec` に自前のスペック JSON を指定する）
- `docs/rules/pr-review-flow.md` / `docs/rules/pr-review-flow-summary.md`
