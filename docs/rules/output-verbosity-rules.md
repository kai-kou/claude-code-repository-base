# 出力 verbosity / 内部作業サイレント原則（Output Verbosity Rules・SSOT）

> **このファイルは「レスポンス本文の verbosity（冗長性）をどう抑えるか」、特に『内部作業の逐次実況をユーザーに垂れ流さない』ことの唯一の正本（Single Source of Truth）である。**
> **Warm 層（タスク依存ではなく常時の行動規範だが、要約を CLAUDE.md 応答スタイル・lessons-core L-111 が Hot で保持するため、本詳細ファイルは Warm に置く）**。
> L-102（AIレビュー対応サイレント原則）と `completion-report-rules.md`（最終報告）の **空白地帯＝「作業中の内部実況」** を埋める。三者は一対で機能する。

---

## 0. なぜ必要か（ユーザー実体験）

本ルールは飼い主の **2 度の明示指摘** から生まれた。**2 つの実況パターン** を等しく対象にする（どちらも同じ「内部作業の垂れ流し」）。

### ケース A: 検証ループの逐次実況（2026-06-16）

> 「たまにユーザーが見てもよくわからない出力がある。トークンを無駄に消費したくないので、こういう出力を抑えてほしい。」

添付されたのは、PR 検証ループで **各ツール呼び出しの間に分析的実況** が積み上がった画面:

```
Test 1 ✓ (awaiting_review, and --mine-only correctly claims ownership via Session-Id). Test 2 — l1-reviewed:negative:
Test 2 ✓. Now the important edge case — both negative AND cleared (negative must win, ...):
Edge case ✓ — negative wins over cleared, confirming L2 must remove negative ...
0 unresolved threads (trivial file ...). Test 3 — remove negative, keep only cleared → expect ready_to_merge:
Test 3 ✓. Test 4 — cleared + an unresolved thread → expect needs_response. ...
```

これは **内部検証プロセスの実況中継** であり、ユーザーには追えない技術ノイズかつ **出力トークンの浪費** である。

### ケース B: 実装ステップの事前宣言（2026-06-18）

> 「ユーザーは実装の進捗詳細に関心がない。チャットに出力してもノイズになりがち。伝えるべきことに厳選してトークン削減・可読性につなげてほしい。」

添付されたのは、実装中に **各ツール（編集）の直前に「これから何をするか」を1文ずつ宣言** していく画面:

```
まずエンジンに multi-series 関数を追加するにゃ。           ← 編集前の宣言
[編集] engine.py +8 -0
Multi-series 用のユーティリティと3関数をエンジン末尾に追加するにゃ。  ← 編集前の宣言
[編集] engine.py +289 -0
__init__.py で新シンボルをエクスポートするにゃ。            ← 編集前の宣言
[編集] __init__.py +8 -0
make_equal_weight_portfolio アダプタを strategies.py に追加するにゃ。 ← 編集前の宣言
[編集] strategies.py +58 -1
```

これは **実装プロセスの逐次中継** であり、ケース A と本質は同じ（内部作業を1ステップずつ実況）。ツール呼び出し列はハーネスが折りたたみ表示するため、**間に挟む「〜するにゃ」宣言は冗長なノイズ** にしかならない。ユーザーは「何ができたか（アウトカム）」だけ知りたい。**CLAUDE.md 応答スタイルは既にこの事前宣言を禁止済み**（「ツール呼び出し前の『〜するにゃ』宣言も省略し無言でツール実行に移る」）だが、ルールが user message であるためドリフトして再発した（→ §6 の output style 強制で対処）。

### 根本原因（3層）

| 層 | 内容 |
|----|------|
| **直接原因** | 内部検証・テスト・探索・デバッグのループで、各ツール呼び出しの間に1〜2文の分析的実況を本文に出力し、status feed 化している |
| **中間原因** | 既存ルールが中間テキスト出力を強く PUSH する（`session-safety-rules.md` ルール3「8ツール→中間報告」/ ルール4「Read 直後に必ずテキスト」/ `progress-reporting-rules.md` 軸A〜C）が、**質と量の上限** を規定していない。タイムアウト防止・制作進捗のための仕組みが、短時間の検証タスクの分析的実況にまで一般化してしまう |
| **根本原因** | verbosity ルールが **非対称**。中間出力への PUSH は強いが、「内部作業の実況は最小化／サイレントにし、ユーザー価値のあるマイルストーンと最終アウトカムだけ表に出す」という **抑制側の統制ルールが欠落** していた。Claude Code の既定 output style は concise だが、蓄積ルールが verbosity 側に上書きしており、それを打ち消す counter-rule が無かった |

> `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1`（設定済み）は **フレーバーテキスト・非必須モデル呼び出し** を止めるもので、**メインモデル本文の実況** は止められない。本文 verbosity は env ではなく **ルール／プロンプトの統制** で対応する領域。

---

## 1. 核心原則: 内部作業はサイレントに、アウトカムだけ表に出す

**検証・テスト・探索・デバッグ・リファクタ・リサーチ・実装（編集）等の「内部作業」の途中経過を、レスポンス本文に逐次実況として垂れ流さない。** 関連するツール呼び出しを **まとめて静かに実行** し、**統合した結論（アウトカム）を1回** で報告する。対象は **「事後の実況（`✓`・所見）」と「事前の宣言（『これから〜するにゃ』）」の両方** である。

```
❌ 検証: Test 1 実行 → 「Test 1 ✓ …」→ Test 2 実行 → 「Test 2 ✓ …」→ … （毎ステップ事後実況）
✅ 検証: Test 1〜6 をまとめて静かに実行 → 「6 ケース全て仕様どおり PASS（baseline / negative / cleared / 競合 / resolve / actionable 除外）にゃ」と1回で報告

❌ 実装: 「engine に関数を追加するにゃ」→[編集]→「__init__ でエクスポートするにゃ」→[編集]→… （毎ステップ事前宣言）
✅ 実装: 関連する編集をまとめて静かに実行 → 「multi-series 対応を実装したにゃ（engine に3関数＋__init__ エクスポート＋strategies アダプタ）」と1回で報告
```

- Adaptive Thinking（思考）の中で検証ロジック・実装計画を回し、**本文には結論だけ** を出す。途中の「いま何を確認しているか」「次に何を編集するか」は思考に留める。
- **ツール呼び出しの直前に「これから〜する」と宣言しない**（無言でツールを実行する）。ツール列はハーネスが折りたたみ表示するため、間に挟む宣言は冗長。CLAUDE.md 応答スタイルの「事前宣言の省略」と同一原則。
- 何ステップあっても、ユーザー向け本文は「やったこと（プロセス）」ではなく「分かったこと・できたこと（アウトカム）」に圧縮する（`completion-report-rules.md` と同じ精神）。

---

## 2. 「出す出力」と「出さない実況」の区別

| 出してよい（ユーザー価値あり） | 出さない（内部実況・ノイズ） |
|-----------------------------|---------------------------|
| 最終アウトカム（`completion-report-rules.md` 構造） | 各テストケース・各検証ステップの逐一の `✓`／所見 |
| 判断の分岐点でユーザーに確認が要る事項（A-1〜A-6） | 「いま X を確認している」「次は Y を見る」の実況宣言 |
| 想定外の発見・方針転換（短く1〜2文） | ツール戻り値の逐次要約（grep/read/test の結果ナレーション） |
| 制作系長時間処理の進捗（§3 の境界に従う場合のみ） | 自分の作業計画の可視化目的の中間メモ |
| エラー・ブロッカーと対処方針（3層原因の要点） | 成功した検証の積み上げ実況 |

**判定基準**: 「この1文は、ユーザーが意思決定・状況把握に使えるか？ それとも自分の作業ログか？」 後者なら本文に出さない（思考に留めるか、最終報告に1行で統合する）。

---

## 3. 既存ルールとの境界（ドリフト防止・最重要）

本ルールは中間出力を PUSH する既存ルールと **矛盾しない**。各ルールの適用範囲を明確に切り分ける。

| 既存ルール | 本来の目的 | 本ルールとの関係 |
|-----------|-----------|----------------|
| `progress-reporting-rules.md` 軸A〜C | **制作系の 5 分超の長時間処理**（音声/画像/動画レンダリング等）のタイムアウト防止＋進捗確認 | **内部検証・探索・テストには適用しない**。短時間タスクのループに進捗実況を持ち込まない |
| `session-safety-rules.md` ルール3「8ツール→中間報告→続き」 | 1ターンのツール過多による Request timed out 防止 | 「中間報告」は **フェーズ境界の1〜2文サマリ（アウトカム）** を指す。**毎ツールの実況ではない**。区切りで1回出す |
| `session-safety-rules.md` ルール4 重要①「Read 直後にテキスト」 | 大きな Read 後の Stream idle timeout 防止 | **大きな Read の直後に限り、短い事実1行**（例: 「確認した。次は X」）。分析・所見の実況にしない。内部検証ループの毎ツールには適用しない |
| L-102 サイレント原則 | AIレビュー指摘対応をユーザーに報告しない | 本ルールは対象を「内部作業全般（検証/探索/テスト/デバッグ）」に拡張した姉妹原則 |
| `completion-report-rules.md` | 最終報告をアウトカム中心にする | 本ルールは「最終報告に至るまでの **途中** を静かにする」ことで、completion-report を引き立てる |

> **覚え方**: progress-reporting は「**制作系の長時間 Bash/ループ**」専用のタイムアウト対策。それ以外の内部作業（検証・調査・実装中の確認）は **本ルール＝サイレント** が既定。

### 3.1 サブエージェント委譲結果の報告は「サイレント対象外」（#375）

**委譲したサブエージェントの成果を統合して報告することは、内部作業の実況ではなくアウトカムの提示である。**
本ルールを根拠に省略・圧縮してはならない。

| 場面 | 扱い |
|------|------|
| 委譲前の宣言（「これから調査を投げるにゃ」）・起動の実況 | ❌ 出さない（本ルールどおりサイレント） |
| サブエージェントの調査ログ・ツール列・途中経過の転記 | ❌ 出さない |
| **完了通知を受け取った後の、結論・根拠・次アクションの統合報告** | ✅ **必ず出す**（本ルールの対象外） |
| 委譲が失敗した・期待外の結果だった事実と対処 | ✅ 出す（ブロッカー報告・A-1〜A-6 の例外規定と同じ扱い） |

**タイミングの注意（仕様・`agent-team.md` §F-8）**: background 実行が既定のため、結果は **後のターンの完了通知** で
届く。通知前に「完了しました」と書くのは L-113（捏造）、通知後に報告を省くのが本項の違反。どちらも避ける。
そのターン内で結果が必要なら `run_in_background: false` で同期実行する。

---

## 4. 良い例 / 悪い例

### ✅ 良い例（検証タスク）

```markdown
（Test 1〜6 を思考内でまとめて実行・本文出力なし）

検証完了にゃ。6 ケース全て仕様どおり挙動した:
- ラベル 5 状態（baseline / negative / cleared / 競合 / resolve）→ 期待どおりの status 遷移
- `--actionable-only` が自セッションのアクティブ PR を正しく除外（L-109）
1 件だけ補足: negative と cleared 併存時は negative 優先（L2 が negative を明示除去する仕様）を確認したにゃ。
```

### ❌ 悪い例（添付画像のパターン）

```markdown
Test 1 ✓ (awaiting_review, and --mine-only correctly claims ownership via Session-Id). Test 2 — l1-reviewed:negative:
Test 2 ✓. Now the important edge case — both negative AND cleared ...:
Edge case ✓ — negative wins over cleared, confirming L2 must remove negative ...
Test 3 ✓. Test 4 — cleared + an unresolved thread → expect needs_response ...
```

→ 各ステップの実況が status feed 化し、ユーザーは追えない・トークンを浪費。**これが「ユーザーが見てもよくわからない出力」の正体**。

### ✅ 良い例（実装タスク・ケース B）

```markdown
（engine.py / __init__.py / strategies.py への編集を事前宣言なしでまとめて静かに実行）

multi-series バックテスト対応を実装したにゃ:
- エンジンに equal-weight ポートフォリオ評価の3関数を追加
- 公開 API（`__init__.py`）と `strategies.py` アダプタを整備
次はテストを通してから PR に進むにゃ。
```

### ❌ 悪い例（添付画像のパターン・ケース B）

```markdown
まずエンジンに multi-series 関数を追加するにゃ。
[編集] Multi-series 用のユーティリティと3関数をエンジン末尾に追加するにゃ。
[編集] __init__.py で新シンボルをエクスポートするにゃ。
[編集] make_equal_weight_portfolio アダプタを strategies.py に追加するにゃ。
```

→ 各編集の **直前に「これから〜する」宣言** を1文ずつ挟み、ツール列の折りたたみ表示と重複したノイズになる。ユーザーは「何ができたか」だけ知りたい。

---

## 5. 判定チェックリスト（本文を1文書く前に自問）

```
[ ] これは「ユーザーの意思決定・状況把握」に使える情報か？（No なら出さない）
[ ] それとも自分の作業ログ・検証/実装の実況か？（Yes なら思考に留め、最終報告に統合）
[ ] ツール呼び出しの「直前」に「これから〜する」と宣言しようとしていないか？（Yes なら省略し無言で実行）
[ ] 制作系 5 分超の長時間処理の進捗か？（Yes のときだけ progress-reporting-rules を適用）
[ ] 大きな Read 直後の stream idle 対策か？（Yes なら短い事実1行のみ・分析実況にしない）
[ ] 同じ「✓」「次は〜」「〜するにゃ」を3回以上繰り返していないか？（繰り返していたら実況の垂れ流し）
```

---

## 6. ハーネス強制レイヤー（output style・ドリフト再発対策）

本ルール・CLAUDE.md 応答スタイルは **user message** として注入されるため、長い実装セッションで **ドリフトして再発** する（ケース B が示す通り、禁止済みでも繰り返された）。これを機械的に補強する唯一の harness レバーが **カスタム output style** である。

### リサーチ結論（2026-06-18・一次情報）

| 機構 | メインモデル本文 verbosity への効果 | 出典 |
|------|--------------------------------|------|
| Hook（PostToolUse / Stop 等） | ❌ 本文を filter/短縮できない（shell スクリプトは出力を傍受しない） | — |
| env（`DISABLE_NON_ESSENTIAL_MODEL_CALLS` 等） | ❌ フレーバーテキスト・サブエージェント呼び出しのみ抑制。本文実況は止まらない | — |
| settings.json ノブ（`verbose`/`maxOutputLength` 等） | ❌ 存在しない。`spinnerTipsEnabled` 等は UI フレーバーのみ | https://code.claude.com/docs/en/settings |
| 組み込み output style `Concise` | ❌ **存在しない**（組み込みは Default / Proactive / Explanatory / Learning のみ） | https://code.claude.com/docs/en/output-styles |
| **カスタム output style** | ✅ **システムプロンプト末尾に追記 + 毎ターン遵守リマインダーを自動注入**。`keep-coding-instructions: true` でコーディング挙動を維持 | https://code.claude.com/docs/en/output-styles |

> **要点**: 本文 verbosity を「機械的に強制」する手段は無いが、**毎ターン自動でリマインダーが入る** のは output style だけ。これが「ルールはあるのに再発する（ドリフト）」への最有効打。CLAUDE.md（user message・圧縮後に再読込はされるが毎ターンリマインダーは無い）を補完する。

### 本プロジェクトの構成

- `.claude/output-styles/concise-neko.md` を配置し、`.claude/settings.json` の `"outputStyle"` で有効化する。
- 内容は **最小限**（日本語ねこキャラ + サイレント内部作業 + 事前宣言/status feed 禁止 + アウトカム中心）に絞り、詳細の正本は本ファイルと `CLAUDE.md` 応答スタイルに置く（**SSOT 二重化を避けるため output style はリマインダーに徹する**）。
- `keep-coding-instructions: true` で既存のコーディング挙動を維持（追記のみ・挙動破壊なし）。
- 反映タイミング: output style はセッション開始時に1度読まれる。変更は `/clear` または新規セッションから有効（既存セッションには即時反映されない）。

---

## 7. 完了・成功の定義

- [ ] 内部検証・テスト・探索 **および実装（編集）ステップ** の逐次実況・事前宣言がレスポンス本文に出ない（思考内で実行し結論のみ報告）
- [ ] 中間出力 PUSH ルール（progress-reporting / session-safety ルール3・4）との境界が明示され矛盾しない
- [ ] CLAUDE.md 応答スタイル・lessons-core L-111 から本 SSOT が参照される
- [ ] output style（`.claude/output-styles/concise-neko.md`）が settings で有効化され、毎ターンリマインダーで verbosity 規律を強制する

---

## 8. 参照

| ドキュメント | 関係 |
|------------|------|
| `CLAUDE.md` 応答スタイル | 本ルールの Hot 要約（常駐・圧縮後も有効） |
| `docs/rules/lessons-core.md` L-111 | 本ルールの Hot 教訓（保持理由付き） |
| `docs/rules/completion-report-rules.md` | 最終報告のアウトカム中心構造（本ルールと一対） |
| `docs/rules/progress-reporting-rules.md` | 制作系長時間処理の進捗報告（本ルールの適用外領域） |
| `docs/rules/session-safety-rules.md` | タイムアウト3種別・8ツール制限・Read limit（中間出力 PUSH 側） |
| `docs/rules/token-optimization-rules.md` | トークン消費最適化（本ルールは出力側の最適化） |
