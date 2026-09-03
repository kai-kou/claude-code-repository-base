# claude-code-base UPDATE NOTES（下流リポジトリ向け移行ノート）

> **目的**: 下流リポジトリで「claude-code-base のアップデートを確認して適用して」と指示された際に、
> **手動手順が必要な更新** を参照するための append-only ノート（新しい順）。
> `scripts/apply-to-repo.sh` がアップデート確認時に、前回適用日以降のエントリを自動で抜粋表示する。
>
> 通常の更新（ルール・スキル・ツールの改良）は `apply-to-repo.sh` の再実行だけで自動同期されるため、
> ここには **書かない**。エントリを書くのは「下流で手動対応が必要な変更」と「下流の運用が変わる周知事項」だけ。

## 記載ルール（ベース側メンテナ向け）

- 下流リポジトリに手動対応（`CLAUDE.md` へのマージ・環境変数の追加・モジュール選択の再判断・breaking change）を
  求める変更を入れた PR では、**同一 PR で本ファイルの先頭（このセクションの直後）にエントリを追記** する
- 見出しは `## YYYY-MM-DD（Issue #N または PR #N）タイトル` 形式（**日付始まりが必須**。
  apply-to-repo.sh がこの日付で「前回適用日以降のエントリ」を機械抽出するため。
  括弧内は追跡できる番号であればよい＝実装中は Issue 番号で書き、PR 採番後の更新は任意）
- 各エントリには以下の 2 項目を書く:
  - **変更内容**: 何が変わったか（1〜3 行）
  - **下流で必要な手動手順**: 下流リポジトリの Claude（または人間）が実施すべき具体的手順。
    コマンド・対象ファイル・判断基準まで書く（「適宜対応」のような曖昧表現は禁止）
- 手動手順が不要な変更にはエントリを作らない（自動同期で完結するため）
- **ファイル削除・リネームを含む PR は追記必須**: `apply-to-repo.sh` の同期（`cp -a`）は
  ファイル削除・リネームを下流へ伝播しないため、base 側で削除したファイルは下流に
  **孤立ファイルとして残り続ける**。削除の事実と下流での手動削除手順を必ずエントリに書く
- 追記漏れは機械リマインドされる: `tools/self_review_check.py`（`pre-pr-create-check.sh` フックが
  自動実行）が、下流影響シグナル（同期対象パスの削除/リネーム・`modules.yaml` /
  `.claude/settings.json` / `CLAUDE.md` の変更・`.claude/rules/` への追加）を含む差分に
  本ファイルの更新が無い場合、PR 作成時に Warning を出す（非ブロック・Issue #211）
- エントリは必ず最初の `---` 区切りより **下** に置く（apply-to-repo.sh は `---` 以降の
  日付形式でない `## ` 見出しを「不正エントリ」として警告する）

---

## 2026-09-03（Issue #543）完了報告の重複出力対策 — PR 確認済みマーカーと続行ターン規律

**変更内容**:
- `.claude/settings.json` の `PostToolUse` に matcher `mcp__github__create_pull_request|mcp__github__list_pull_requests`
  → `.claude/hooks/post-pr-confirm-mark.sh`（新規）を追加した。現在ブランチの PR 実在（作成成功・または
  open / merged の PR を含む一覧応答）を観測してセッションローカルのマーカーを立て、`stop-pr-check.sh` の
  クラウド分岐はマーカーがあれば「PR 存在確認をお願いします」で差し戻さない（毎ターンの差し戻しを抑止）。
- `stop-router.sh` は差し戻し集約の末尾に `[continuation]` タグ、`stop-completion-report-check.sh` は
  `[report-format]` タグを付け、後者は「適正な完了報告済み」セッションマーカーで以後の nudge を抑止する。
  最終メッセージの取得は公式推奨の `last_assistant_message` を優先する。
- `docs/rules/completion-report-rules.md` §1.2（Stop フック差し戻し後の続行ターンでは完了報告を再掲しない）を
  新設し、`CLAUDE.md` 完了報告節と `.claude/output-styles/concise-neko.md` に 1 行ずつポインタを追加した。

**下流で必要な手動手順**:
- `.claude/settings.json` は 3 方向マージで自動反映される。衝突した場合は `.claude/settings.json.base-latest` と
  見比べて上記 `PostToolUse` エントリを手動で追記すること。
- `CLAUDE.md` は保護対象のため自動反映されない。「セッション完了報告」節の末尾に次の 1 行を追記すること:
  `**\`Stop hook feedback:\` で始まる続行ターンでは完了報告を再掲しない**（確認結果を 1〜3 行。\`[report-format]\` があるときだけ簡潔に書き直す）。切り分けの正本は同ファイル §1.2（#543）。`
  あわせてハーネス表の「事後検証」行に `post-pr-confirm-mark.sh` を足す（全 23 スクリプト）。
- 下流で独自に `stop-pr-check.sh` を改変（例: `--mark-confirmed` フラグ）している場合は、本ベースの
  PostToolUse 観測方式に置き換えるか、両立させるかを判断すること（マーカーのファイル名は
  `claude-pr-confirmed-<session_id>-<branch_key>`・`lib/hook_layer1_common.sh` の `hook_branch_key()` でキー化）。

---

## 2026-09-03（Issue #512）マージ前に Layer 1 セルフレビュー実施をハーネスで観測する非ブロッキング nudge を追加

**変更内容**:
- `.claude/settings.json` に `PreToolUse`（matcher: `mcp__github__merge_pull_request`）と
  `PostToolUse`（matcher: `mcp__github__pull_request_review_write`）の新規フックエントリを追加した。
  `.claude/hooks/post-review-write-mark.sh` がレビュー提出（`method=create`+`event` または
  `method=submit_pending`）を検知しセッションローカルのマーカーを記録し、
  `.claude/hooks/pre-merge-layer1-check.sh` がマージ直前にマーカー未観測なら
  `additionalContext` で非ブロッキング警告を出す（Layer 1 セルフレビューの実施をモデルの
  自主性任せにせず機械観測する。ハードブロックはしない設計 — 詳細は各スクリプト冒頭コメント）。

**下流で必要な手動手順**:
- 通常は不要（`apply-to-repo.sh` の 3 方向マージが新規フックエントリを自動反映する）。
- ただし下流が `.claude/settings.json` の `PreToolUse` / `PostToolUse` を独自にカスタマイズ済みで
  マージ衝突が起きた場合は、`.claude/settings.json.base-latest` と見比べて上記 2 エントリを
  手動でマージ先へ追記すること。

## 2026-09-02（Issue #509）modules.yaml 専用マージャ（merge_modules_yaml.py）を廃止・通常の3方向マージへ統合

**変更内容**:
- `apply-to-repo.sh` の `SEMANTIC_MERGE_PATHS`（`modules.yaml` だけ行ベース 3 方向マージから除外する
  特別扱い）を廃止し、他の `SYNC_PATHS` と同じ「ベース無変更ならスキップ / 下流が祖先のままなら更新 /
  両側変更なら 3 方向マージ / 衝突なら下流温存 + `.base-latest` 併置」の 4 分岐へ統合した。
- `scripts/merge_modules_yaml.py`（`enabled:false` / `project:` の 3 キーだけを個別復元する専用
  スクリプト）を削除した。合成ケース検証（Issue #509）で、旧方式は復元対象外のカスタマイズ
  （独自モジュール追加・コメント追記等）を再適用のたびに無条件で消していたことを確認した一方、
  3 方向マージはそれらも自動保持し、真の衝突（同一行の書き換わり）時も他ファイルと同じく
  安全側（下流温存）に倒れることを確認した。

**下流で必要な手動手順**:
- 通常は不要（挙動はより安全になる方向の変更で、`enabled:false` / `project:` の保護は引き続き働く）。
- ただし過去の適用で `modules.yaml` への独自カスタマイズ（`enabled:false` 以外のコメント・独自モジュール
  追加等）が既に消えている場合は復元されない（マージは今ある状態を守るだけ）。
  `git log --all -p -- modules.yaml` から消失前のコミットを探し、1 回だけ手で戻すこと。

## 2026-08-30 apply-to-repo.sh を祖先つき 3 方向マージに変更・下流独自ルールは docs/rules/local/ へ

**変更内容**:
- `SYNC_PATHS` 配下と `.claude/settings.json` の同期を、`cp -a` の無条件上書きから
  **前回適用したベース SHA を祖先とする 4 分岐** へ変更した（ベース側が無変更なら触らない /
  下流が祖先のままなら更新 / 両側変更なら 3 方向マージ / 衝突・検証失敗なら下流を温存して
  `<path>.base-latest` を併置）。衝突マーカーはワークツリーに書かれない。
- 検証ヘルパー `tools/merge_three_way.py` を追加した（衝突マーカー・JSON 構文・**重複キー** を検証し、
  通らないマージ結果は採用しない）。
- `--no-merge`（旧来の無条件上書きへ戻す退避経路）と、適用後の **同期サマリー** を追加した。

**下流で必要な手動手順**:
1. 【今回の適用直後】表示された同期サマリーを確認する。`要確認` に挙がったファイルは
   `diff <path> <path>.base-latest` で内容を取り込み、済んだら `.base-latest` を削除してから
   コミットする（`.base-latest` を残したままコミットしない）。`マージ` に挙がったファイルは
   コミット前に `git diff` を確認する（特に `hooks` / `permissions` など並び順に意味がありうる配列）。
2. 【`.claude/settings.json` / `.mcp.json`】原則、今回以降の適用で下流のカスタマイズ（独自フック
   matcher・`permissions` 追加・`sandbox` 許可ホスト・独自 MCP サーバ）は自動で保持される。
   **ただし過去の適用で既に消えている分は復元されない**。`git log --all -p -- .claude/settings.json .mcp.json`
   で消失前のコミットを探し、1 回だけ手で戻すこと。
3. 【`docs/rules/`】ベース管理下のルールファイルに直接書いていた下流独自節は、
   `docs/rules/local/{同名}-local.md` へ **1 回だけ手で切り出す**（自動移設はしない）。
   以後その独自ルールは適用対象外になり、恒久的に上書きされなくなる。常駐させたい場合は
   下流側で `.claude/rules/` へ symlink する。
4. 【前提】`.claude/base-sync-state.json` がコミットされていること。無いと祖先を特定できず
   従来どおりの上書き同期になる（サマリーに「祖先: 未使用」と表示される）。


## 2026-08-08（Issue #452）着手時プラン提示ルールを追加（`CLAUDE.md` 応答スタイル節に 1 行のマージが必要）

**変更内容**:

- `docs/rules/output-verbosity-rules.md` に **§1.1「タスク着手時の 1 回限りのプラン提示（必須）」** を新設した。
  L-111（逐次事前宣言の禁止）の過剰適用で、ユーザー指示直後に「これから何をするか」を伝えないまま
  作業へ入る事象が発生していたため、境界を **アンカーイベント**（新規タスク性ユーザー指示への応答で
  最初のツール呼び出し前の 1 回）で定義し直した。委譲を伴う場合は WHAT（到達点）を述べ HOW（委譲という
  手段）は述べない、という §3.1 との切り分けも明記した。
- 同期先: `.claude/output-styles/concise-neko.md`（新節 + 例外リスト）・`docs/rules/lessons-core.md`
  （L-111 の「のみ」を修正 + **L-124 を新設**）・`.claude/hooks/prompt-structuring.sh`（テンプレ出力禁止を
  逐語出力に限定し、圧縮した平文 3〜5 行の報告を明示要求。`_verb_re` に非実装系動詞を追加）。
- 上記のうち **`CLAUDE.md` 以外は `apply-to-repo.sh` の再実行で自動同期される**。

**下流で必要な手動手順**:

1. 下流の `CLAUDE.md`「応答スタイル」節（プロジェクト固有ファイルのため自動同期されない）に、
   ベース側の該当 2 行をマージする:
   - 既存の「ツール呼び出し前の『〜するにゃ』という宣言も省略し…」を
     **「2 回目以降の** ツール呼び出し前の…逐次宣言は省略し…」に書き換える
   - 直後に **「着手時のプラン提示は必須（`output-verbosity-rules.md` §1.1）」** の 1 行を追加する
   （ベース側の現行文言は `CLAUDE.md` の「応答スタイル」節をそのまま参照すればよい）
2. 応答スタイルを独自に差し替えているプロジェクト（敬体・英語・ニュートラル等）は、
   `.claude/output-styles/<自前スタイル>.md` にも「着手時プラン提示は必須」を同じ語調で追記する
   （output style はセッション開始時に 1 度読まれる。変更は `/clear` または新規セッションから有効）。
3. 手順 1 を省略すると、**セッション圧縮のたびに新義務が失われて元の全面禁止に戻る**
   （圧縮後にディスクから確実に再読込されるのは `CLAUDE.md` と `.claude/rules/` のみ）。

## 2026-08-08（Issue #448）config/ を配布対象に追加・下流に届かないパス参照の解消

- **変更内容**: ① `scripts/apply-to-repo.sh` の配布定義に `config/` の 5 ファイルを性質ごとに追加した
  （`SYNC_PATHS` に `config/claude_code_spec_sync.yaml`・`config/broker_workflows.json.example`、
  `PROTECT_PATHS` に `config/publish_events.yaml`・`config/data_only_path_prefixes.txt`・
  `config/pr_review_comment_categories.json`）。`config/backlog_refinement_state.json` は実行状態そのもので、
  配ると新規下流の週次ゲートが著者環境のタイムスタンプで誤抑制されるため **配布対象外**（公開スナップショットからも除外）
  ② 本ファイルへの参照 2 件（`apply-base` / `audit-runner` の SKILL.md）を地の文へ言い換えた。本ファイルは下流に
  配置されず `apply-to-repo.sh` が実行時に読み上げる設計のため、パス表記のままだと全下流でリンク切れとして検出され続けていた
  ③ `tools/check_skill_references.py` に `--downstream` モードを追加し、配布定義（`SYNC_PATHS` + `PROTECT_PATHS`）に
  届かないパスを SKILL.md / ルールが参照していないかを機械検知できるようにした。下流の再現環境でリンク切れが
  **6 件 → 0 件**（`config/` 未配布が原因の 4 件も同時に解消）
- **下流で必要な手動手順**: ① 再適用すると `config/claude_code_spec_sync.yaml` と
  `config/broker_workflows.json.example` は **ベース版で無条件上書き** される。この 2 件を独自に書き換えている
  下流は、再適用前に差分を退避すること（以後はベースの更新が自動的に届く）
  ② `config/publish_events.yaml`・`config/data_only_path_prefixes.txt`・`config/pr_review_comment_categories.json` は
  **既存があれば保護** され、ベース版は `<パス>.base` として並置される。プロジェクト固有の追記を保ったまま、
  `.base` と見比べてベース側の新しい既定値を取り込むこと（`.base` の取り込みは `apply-base` スキル §3 の手順と同じ）
  ③ `config/backlog_refinement_state.json` は配布されない。既に持っている下流はそのまま維持され、
  持っていない下流は `self-improvement-loop` の初回実行時に自動生成される（手動作成は不要）
## 2026-08-08（Issue #449）PostToolUse フックを追加（`.claude/settings.json` に配線 1 行の追記が必要）

**変更内容**:

- `.claude/hooks/post-merge-publish-check.sh` を新設した。`mcp__github__merge_pull_request` の成功を
  PostToolUse で検知し、公開反映レーンのドリフトを判定して反映指示を注入する。
- ベース側では「main へマージした瞬間」を配布反映の主経路に変更した（従来はセッション終了時と
  4 時間周期のルーティン頼みで、反映が最大十数時間滞留していた）。
- `.claude/hooks/session-start.sh` に、公開反映レーンの回収指示を注入する分岐を追加した
  （`tools/check_publish_drift.py` が存在するときだけ出力する）。

**下流で必要な手動手順**:

- **公開リポジトリへスナップショットを配る運用（publish-sync レーン）を持たない下流では、対応不要**。
  新フックは `tools/check_publish_drift.py`（ベース側でのみ配布される）が無い環境では即 `exit 0` し、
  `session-start.sh` の分岐も出力しないため、配線を入れても無害に不発する。
- 自前の publish レーンを持つ下流、またはベースと同じ配線を保ちたい下流は、`.claude/settings.json` の
  `hooks.PostToolUse` 配列に次の 1 エントリを追記する（既存の `post-tool-use-validate.sh` エントリは残す）:

  ```json
  { "matcher": "mcp__github__merge_pull_request", "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/post-merge-publish-check.sh", "timeout": 90 } ] }
  ```

- 配線後は `bash .claude/hooks/post-merge-publish-check.sh --self-test` が `PASS=12 FAIL=0` を返すことを
  確認する（検知ロジックと origin URL 解析のみのテストで、ネットワークに依存しない）。

---

## 2026-08-02（下流リポジトリの実測監査からの還流）機密ファイルガードを全面刷新（下流で同ファイルを独自改変している場合は差し替えてください）

**変更内容**:

- `.claude/hooks/pre-tool-use-router.sh` の機密ファイル判定を、正規表現一発から **段階判定** に作り直した。
  ① 候補トークン抽出 → ② 秘密ディレクトリ（`~/.ssh` / `~/.aws` / `~/.gnupg`）→ ③ ベース名スコープの
  拡張子判定・語境界判定 → ④ 文書拡張子は除外。
- **塞いだ取りこぼし**（下流で実測・いずれも旧実装では素通り）:
  - コマンド置換・サブシェル経由（`echo "$(cat ~/.ssh/id_rsa)"` / `` `cat …` `` / `(cat …)`）。
    境界文字集合に `(` とバッククォートが無かった。**`.env` ガードも同じ穴を持っていた**。
  - 前置語つきの実ファイル名（`gcp-service-account.json` / `gcp-credentials.json` / `backup-id_rsa` /
    `~/.aws/my-credentials`）。旧実装はベース名先頭一致限定だった。
  - 対象ファイル種別を `.git-credentials` / `.netrc` の 2 種から、鍵・証明書（`*.pem` / `*.key` /
    `*.p12` / `*.pfx` / `*.jks` / `*.keystore`）と認証情報の語（`credentials` / `service-account` /
    `id_rsa` 系）へ拡張した。
- **解消した誤検知**（下流で実測。うち 1 件は監査セッション自身がライブで踏んだ）:
  `cat config/credentials/README.md`（ディレクトリ名の一致）・`cat notes/service-accountability.md`
  （部分語の一致）・`find . -name credentials` / `ls . credentials` / `git status . x`
  （`_sfa_cmds` の `\.`＝dot source がカレントディレクトリ引数と区別できなかった）。
- **議論型レビューで追加是正した 4 点**（配布元での採用時に実測・#393）:
  - 公開鍵 `id_rsa.pub` が語境界判定でブロックされていた → `*.pub` を除外に追加。
  - `docs/.ssh/README.md` のような文書パスが秘密ディレクトリ判定に先取りされていた
    → 文書拡張子の除外を秘密ディレクトリ判定より **先に** 評価する順序へ変更。
  - 秘密ディレクトリ判定が末尾スラッシュ必須・大文字小文字区別だったため
    `cp -r ~/.ssh /tmp` / `cat ~/.SSH/config` が素通りしていた → `(/|$)` アンカー + `-i` へ。
  - dot source を対象から外したことで `. .env` が素通りしていた（`source .env` は塞がるのに
    POSIX 上の同義語である `. .env` が通る非対称）→ **コマンド位置（行頭 or 区切り直後）の `.` に
    限定して** 抽出し直し、`find . -name credentials` 等の誤ブロックは再発させない。
- **Layer 1 セルフレビューで追加是正した 3 点**（#396）:
  - 文書拡張子の除外が秘密ディレクトリ判定より先に効いていたため、`~/.ssh/id_rsa.md` のように
    **拡張子を変えるだけでディレクトリ保護を無効化できた** → 秘密ディレクトリ判定を先に評価する順序へ戻し、
    一致条件を **ホーム基準・絶対パス・先頭要素** に限定して `docs/.ssh/README.md` の誤検知は回避したまま解消。
  - 拡張子・語境界の判定が大文字小文字を区別し `foo.PEM` / `ID_RSA` が素通りしていた
    （秘密ディレクトリ判定だけ `-i` で不整合）→ 小文字化した文字列で判定するよう統一。
  - ブロックメッセージの「語を含むファイル」という文言が実際の語境界判定より緩く読めた → 「語境界で一致」に修正。
- `tools/test_sensitive_file_guard.sh` を追加（BLOCK 36 / ALLOW 20 の 56 ケース）。
  **ALLOW 側のケースを削らないこと** — 誤検知で通常運用が止まる実害は、取りこぼしと同じ重さで扱う。
- `docs/rules/security-posture-controls.md` に deny の **cwd アンカー射程**（cwd 内は Bash の `cat` にも
  deny が効く／cwd 外は射程外）と、第2層の判定限界・任意サブプロセスを塞げない恒久的限界を明記した。

**下流で必要な手動手順**:

1. `apply-to-repo.sh` を再実行して `.claude/hooks/pre-tool-use-router.sh` と
   `tools/test_sensitive_file_guard.sh` を同期する。
2. **`pre-tool-use-router.sh` に下流固有の分岐を足している場合は上書きで消える**。同期前に
   `git diff` で自リポジトリ側の追加分岐（MCP 経路のガード・プロジェクト固有チェック等）を確認し、
   新実装の上へマージし直す。
3. 同期後に `bash tools/test_sensitive_file_guard.sh` を実行し `FAIL=0` を確認する
   （`package.json` を持つリポジトリは `"test:sensitive-file-guard": "bash tools/test_sensitive_file_guard.sh"` を
   登録して `npm run test:sensitive-file-guard` で回せるようにする）。
4. `docs/rules/security-posture-controls.md` §1.1 の deny 列挙を **自リポジトリの実 `settings.json` から
   写し直す**（雛形の列挙をそのまま残すと「設定済みだから安全」という誤った前提が生まれる。
   下流で実際に desync していた）。

---

## 2026-08-02（Issue #389）`audit-runner` スキルを追加（定期実行するかどうかを選んでください）

**変更内容**:

- 外部の監査プロトコル（既定は [claude-code-ultimate-guide の audit-prompt.md](https://github.com/FlorianBruniaux/claude-code-ultimate-guide/blob/main/tools/audit-prompt.md)）を
  **実行のたびに取得** して忠実に実行し、指摘を **議論型レビューで精査** → 採用分のみ Issue 化 → 実装 →
  PR → マージ → **同一版で再監査して before/after を対比** するスキル `audit-runner` を追加した。
- 監査スコアを鵜呑みにせず、指摘ごとに「真の欠陥 / 意図的な設計選択 / 著者の独自慣習の押し付け」を
  判定するのが中核。点数だけが上がる変更は採用しない設計。
- 成果物は `content/audits/<YYYY-MM-DD>/`（`protocol.md` / `before.md` / `after.md` / `diff.md`）に残る。

**下流で必要な手動手順**:

1. **手動実行のみで運用するなら、何もしなくてよい**（自然文「セットアップを監査して」または
   `/audit-runner` で起動する）。同期しただけで使える。
2. **定期実行したい場合のみ**、次のいずれかを登録する（SKILL.md「定期実行の登録」節に手順あり）:
   - Routine（クラウド）: `create_trigger` で `create_new_session_on_fire=true` の Routine を作り、
     プロンプトに「`audit-runner` スキルで監査プロトコルを実行し、議論 → 対応 → 再監査まで完遂する」と書く。
     cron は UTC 指定（JST から 9 時間引く）。**推奨頻度は月次**（1 サイクルでサブエージェント 4〜6 体分を消費する）
   - 既存ルーティンのスロットに 1 行追加して本スキルを起動する
3. 別の監査プロトコルを使いたい場合は、環境変数 `AUDIT_PROTOCOL_URL` で上書きする（1 実行 = 1 プロトコル）。
4. `content/audits/` を追跡したくないリポジトリは `.gitignore` に追加する（既定では追跡される）。

---

## 2026-08-02（Issue #383）`sandbox.enabled: true` を追加（ローカル環境でネットワーク許可リストが実際に効き始めます）

**変更内容**:

- `.claude/settings.json` の `sandbox` に **`enabled: true` を追加** した。従来は `allowedDomains` /
  `excludedCommands` を書いていたが `enabled` が無いためサンドボックス自体が起動しておらず、
  許可リストは **一切機能していなかった**（許可リスト外ドメインへ Bash から到達できることを実機確認）。
- あわせて `.git-credentials` / `.netrc` を `permissions.deny` と `pre-tool-use-router.sh` の
  両層でブロックするようにした（Issue #384）。
- `failIfUnavailable` は **意図的に追加していない**（サンドボックス不可の環境でセッション起動自体が
  失敗し、無人セッションが沈黙するため）。

**下流で必要な手動手順**:

1. `apply-to-repo.sh` の同期後、**自リポジトリの `.claude/settings.json` の `sandbox.network.allowedDomains`
   を見直す**。これまで許可リストは無効だったため、有効化によって **今まで通っていた外部通信が
   遮断される可能性がある**（ローカル実行時。`bwrap` / Seatbelt が使える環境）。
   自プロジェクトが実際に接続するドメイン（独自 API・パッケージレジストリ等）を洗い出して追加する。
2. 検証方法: ローカルで Claude Code を再起動し、Bash から許可リスト外のドメインへ
   `curl -s -o /dev/null -w "%{http_code}" https://example.com/` を実行してブロックされることを確認する。
   通ってしまう場合は `enabled` が反映されていないか、環境に `bwrap` が無い。
3. **クラウド実行環境（Claude Code on the web）では `bwrap` が存在せずサンドボックスは動作しない**
   （実機確認済み）。クラウドのみで運用しているなら手順 1・2 は不要だが、ローカル実行や下流配布を
   行うなら実施すること。詳細は `docs/rules/sandbox-rules.md`。

---

## 2026-08-01（Issue #379）ベースの配布元を公開リポジトリへ分離（apply-base の取得元が変わります）

**変更内容**:

- ベースの配布元が **公開リポジトリ `kai-kou/claude-code-repository-base`** になった。
  開発は従来どおり別リポジトリ（private）で行い、配布物だけを履歴なしのスナップショットとして公開側へ置く。
  これにより **ベースへのアクセス権がなくても `apply-base` / `apply-to-repo.sh` が使える** ようになった。
- 配布物の既定値を 2 点、安全側へ変更した（下流にもそのまま配布される）:
  - `.claude/settings.json` の `sandbox.excludedCommands` から `python3 *tools/*.py` 系の
    ワイルドカードを削除した。従来は **`tools/` 配下の任意の Python がネットワーク allowlist を
    無条件でバイパス**していた。現在は動的接続が必要な 2 本（secrets-broker 移行ツール）のみに限定。
  - `tools/check_pending_pr_reviews.py` の自動マージ判定に **著者検証**（`authorAssociation` が
    OWNER / MEMBER / COLLABORATOR）を追加した。従来はブランチ名の前方一致だけで判定しており、
    public リポジトリでは第三者の fork PR が無人マージ経路に到達しうる状態だった。
- `base-harvest` スキルは配布対象から外れた（配布物の受け手には使い道がない運用スキルのため）。

**下流で必要な手動手順**:

1. **`.claude/settings.json` の再確認**（`apply-to-repo.sh` は既存の settings.json を上書きしないため、
   下流側は自分で反映する必要がある）:
   - `sandbox.excludedCommands` に `python3 *tools/*.py` 系のワイルドカードが残っていたら削除する。
     削除後にツールが外部へ接続できなくなった場合は、**除外を戻すのではなく**
     `sandbox.network.allowedDomains` に必要な宛先を追加して解決する。
   - 判断根拠は `docs/rules/sandbox-rules.md`。
2. **`tools/check_pending_pr_reviews.py` を使っている場合**: 著者検証が入ったため、
   `authorAssociation` を取得できない経路では PR が自動処理の対象外になる（fail-closed）。
   クラウドでは `mcp__github__*` にこのフィールドが無いため、`gh` 経路または
   `list_repository_collaborators` によるフォールバックが要る（`docs/rules/github-mcp-fallback-patterns.md`）。
   自分の PR が拾われなくなった場合はここを疑うこと。
3. **`base-harvest` を使っていた場合**: 配布対象外になったため、次回の `apply-to-repo.sh` 実行後も
   既存ファイルは残るが更新されない。還流が必要なときは開発リポジトリ側のセッションで実行する。
4. **リモート URL の変更は不要**: 下流リポジトリ自体の remote は変わらない。
   変わるのは `apply-to-repo.sh` の `--base` 既定値（＝ベースの取得元）だけで、
   `apply-base` スキル経由なら自動的に新しい取得元が使われる。

## 2026-07-26（Issue #342）gh 非依存化 — ハーネス・スキル・ドキュメントを MCP メイン前提へ移行

- **変更内容**: #338 の実測（クラウドでは gh が未提供・導入しても repo REST は 403）を受け、
  **「gh が無い前提で全機能が成立する」状態** へ資産全体を移行した。gh 経路自体はローカル実行の互換として残す。
  - `session-start.sh`: **クラウドでの `apt install gh` を廃止**（毎セッションの無駄な導入を停止）。
    `GH_TOKEN` 未設定を警告しなくなり（`proxy-injected` が正常）、GitHub Variables ロードは
    クラウドでスキップする（プロキシが 403・MCP にも等価ツール無し）
  - `stop-pr-check.sh`: クラウドでは gh 試行をやめ、「⚠️ PR 確認できません（異常）」ではなく
    **「Claude が MCP で PR 存在を確認する」指示** を返すようになった（gh 不在は既定であり障害ではない）
  - `post-tool-use-failure.sh`: 403 ガイダンスから「repo スコープ REST は許可」という旧情報を削除し、
    MCP ツール一覧へ誘導する内容に是正
  - `.claude/skills/` 13 ファイル: 冒頭に「本ファイル内の `gh` はローカル実行専用。クラウドは
    `mcp__github__*`」という必読ブロックを追加。`pr-review-watcher` の返信・Resolve 手順は
    MCP（`add_reply_to_pull_request_comment` / `resolve_review_thread`）一次に書き換え
  - `.claude/commands/next.md`: レビュー待ち PR の確認をクラウドでは MCP 一次に変更
    （`check_pending_pr_reviews.py` はクラウドで必ず exit 3 になるため）
  - `README.md` / `scripts/apply-to-repo.sh` / `scripts/bootstrap.sh`: ベース取得を **git 一次**（gh はフォールバック）へ、
    env 登録案内を Claude.ai 環境設定へ変更
  - lessons L-050 / L-115: PR 存在確認・マージ検証の一次手段を MCP に是正
- **下流で必要な手動手順**:
  ① **`CLAUDE.md` の gh 節を base 版に合わせて更新する**（保護対象のため自動反映されない）。
  「クラウドは MCP 一次経路・gh は当てにしない」「403 の切り分けは `gh api user` が 200 かで判定」
  「git 操作は別プロキシで生存」の 3 点が入っているかを確認する。
  ② 自リポジトリ独自のスキル・スクリプトに `gh` 前提の手順があれば、
  `docs/rules/github-mcp-fallback-patterns.md` §2 の対応表で `mcp__github__*` へ読み替える
  （MCP に等価が無いラベル一覧/作成・マイルストーン・release 作成・variables はクラウドで実行不可と明記する）。
  ③ `session-start.sh` を base 版に追従していない下流は、**クラウドでの gh 自動インストールが残っていないか**
  確認して外す（セッション起動が数十秒遅くなるだけで効果がない）。
  ④ フック・`tools/*.py` が gh 失敗時に空リスト・0 件へサイレント縮退していないか点検する
  （正しい形は `gh_unavailable` / 専用 exit code で失敗を明示し、呼び出し元の Claude が MCP で引き取る）。

## 2026-07-26（Issue #338）クラウドの gh 可否を再実測 — repo スコープ REST が 403 へ回帰

- **変更内容**: 2026-07-14 に「許可へ転換」と記録した repo スコープ REST（`gh api repos/{o}/{r}/...`）が
  **2026-07-26 実測では 403 へ回帰** していた。あわせて **`gh` はクラウドにプリインストールされない**
  （公式仕様）ことが確定し、`apt install gh` で導入しても repo API が 403 なら実益がないことを実測で確認。
  403 の原因は認証ではなく **リポジトリが GitHub API アクセス付きでセッションに attach されていないこと**
  （`gh api user` は 200 で返る）。SSOT（`github-mcp-fallback-patterns.md`・L-114・CLAUDE.md の gh 節）を
  「MCP 一次経路 / git は別系統 / gh は当てにしない」へ是正した。gh シム・gh 依存スクリプトは
  ローカル互換と 403 検知ガイダンスのため **削除していない**（挙動変更なし）
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` の gh 節が **2026-07-14 版の三層記述
  （「シム + repo REST + MCP」「repo REST は動作する」）** になっている場合、base 版の
  「クラウドは MCP 一次経路・gh は当てにしない」へ更新する（CLAUDE.md は保護対象のため自動反映されない）。
  ② 自リポ独自のスクリプト・スキルが `gh api repos/...` の成功を前提にしている箇所があれば、
  失敗時に `gh_unavailable` を明示して MCP へ委譲する形（`tools/check_pending_pr_reviews.py` が参考実装）に直す。
  ③ 可否は今後も変動しうるため、疑わしいときは
  `curl -o /dev/null -w '%{http_code}' https://api.github.com/repos/{owner}/{repo}` の HTTP コードで再確認する

## 2026-07-24（Issue #314）モデル指定をエイリアス（opus/sonnet/haiku）既定に統一

- **変更内容**:
  モデル世代交代のたびに追随作業が発生する問題を解消するため、運用ファイルのモデル指定を
  **エイリアス（`opus` / `sonnet` / `haiku` / `fable`）既定** に統一した。ベース側では
  `.claude/settings.json` の `model` を `claude-sonnet-5` → `sonnet` に変更し、
  `agent-team.md` に「モデル指定の方針」を SSOT として新設（厳密 ID を書いてよい 3 例外・
  エイリアスが使える場所の一覧・provider 差異を記載）。`tools/discussion_specs/*.json` の
  `model` も full ID からエイリアスへ置換した（ネイティブ `discussion-review` が使う Agent ツールの
  `model` はエイリアスのみ受理するため、既存の不整合の修正も兼ねる）。

- **下流で必要な手動手順**:
  1. `.claude/settings.json` は下流の保護対象（プロジェクト固有設定）のため自動同期されない。
     下流の `.claude/settings.json` を開き、`"model": "claude-sonnet-5"` のように **厳密バージョン ID が
     書かれていれば `"sonnet"`（または用途に応じて `"opus"` / `"haiku"`）へ書き換える**。
     既に `"sonnet"` 等のエイリアスなら変更不要。
  2. 下流固有のスキル・サブエージェント定義（`.claude/skills/*/SKILL.md` ・ `.claude/agents/*.md` の
     frontmatter `model:`）に `claude-opus-4-8` のような厳密 ID が残っていないか
     `grep -rn "claude-opus-\|claude-sonnet-\|claude-haiku-" .claude/` で確認し、
     エイリアスへ置き換える（残す場合は「再現性のための意図的ピン留め」である旨をコメントで残す）。
  3. 下流独自のツールが `claude -p --model <full ID>` や Anthropic API 以外の経路でモデルを
     渡している場合も同様にエイリアス化する。**Anthropic API を直接叩くコードと料金表など ID を
     キーにする実装は full ID のまま**（エイリアス不可）。
  4. **provider 注意**: 下流が Bedrock / Google Cloud / Foundry 経由の場合、`sonnet` は旧世代に
     解決される。最新世代を使いたい場合は `ANTHROPIC_DEFAULT_SONNET_MODEL` /
     `ANTHROPIC_DEFAULT_OPUS_MODEL` で解決先を上書きする。

---

## 2026-07-21（Issue #280）組み込み /code-review を自前 code-review スキルで置き換え（Layer 1 標準実行手段）

- **変更内容**:
  組み込み `code-review` スキルが v2.1.216 で `disable-model-invocation` となり Claude の自律起動が
  不可になったため、同名 project スキル `.claude/skills/code-review/`（自前実装）で bundled を置換した
  （公式のスキルオーバーライド仕様を利用）。対話（`/code-review` 手打ち）・自律（`Skill(code-review)`）の
  両方から起動可能で、FAIR Layer 1 の標準実行手段を本スキルに統一。`modules.yaml` の `pr-review`
  モジュールに `code-review` を追加し、`ai-reviewer-strategy.md`・`pr-review-flow*.md`・
  `self-reviewer`/`pr-review-watcher`/`retro-try-handler`/`project-manager`/`claude-code-spec-sync` の
  各 SKILL.md・`pre-pr-create-check.sh`・`check_pending_pr_reviews.py`・`detect_pr_diff_type.py`・
  `CLAUDE.md` スキル表を整合修正（L-119 に恒久対策を追記）。
- **下流で必要な手動手順**:
  - 基本は `scripts/apply-to-repo.sh` の再実行で自動同期される（`.claude/skills/code-review/` が展開され、
    次セッションから `Skill(code-review)` が自律起動可能になる）。
  - 下流独自の CLAUDE.md を保護運用（`--overwrite-project` なし）しているリポジトリは、スキル表に
    `code-review` の行を手動で追記し、「Layer 1 は self-reviewer Step 2 で実行」と書いた独自記述が
    あれば「Layer 1 は自前 `code-review` スキル（`Skill(code-review)`）で実行」へ更新する。
  - 下流で `.claude/skills/code-review/SKILL.md` に `disable-model-invocation: true` を **追加しない**
    こと（追加すると自律起動が再び不能になり本置換の意味が消える）。

## 2026-07-17（Issue #264）Claude Code 仕様変更追随レーン（claude-code-spec-sync）を新設

- **変更内容**:
  Claude Code 本体のバージョンアップ（changelog/releases）を定期検知し、破壊的変更は即対応・
  新機能は検証フェーズを経て内部資産（rules/skills/hooks/settings）へ反映するレーンを追加した。
  新規: `tools/check_claude_code_updates.py`・`config/claude_code_spec_sync.yaml`・
  `docs/rules/claude-code-spec-sync.md`（Warm 層）・`.claude/skills/claude-code-spec-sync/`。
  `modules.yaml` に `claude-code-spec-sync` モジュール、`CLAUDE.md` のスキル表・タスク依存ルール一覧に
  エントリを追加。`claude-code-optimization.md` 末尾に「バージョン差分ログ」記録先セクションを新設。
- **下流で必要な手動手順**:
  - Issue 起票に使うラベルを作成する（存在しないと REST 経由の起票が失敗しうる）:
    ```bash
    gh label create "lane:claude-code-spec" --color 1d76db --description "Claude Code 仕様変更追随レーン（claude-code-spec-sync）"
    ```
  - 定期実行を配線する（いずれか）: ① 既存の定期ルーティン/スケジュールタスクのプリフライトに
    `python3 tools/check_claude_code_updates.py --create-issue` を追加（本リポジトリは
    `docs/routines.md` R-1 手順 3 が実装例）② 手動運用（`/claude-code-spec-sync`）のみで開始。
  - 初期 state を既知化してから運用を開始する（しないと初回に過去バージョン分の Issue が
    まとめて起票される）: `python3 tools/check_claude_code_updates.py --dry-run >/dev/null` を実行後、
    `--create-issue` なし実行は起票対象を既知化しない仕様のため、過去分を捨てたい場合は
    `config/claude_code_spec_state.json` を base 同梱の state（現行バージョンまで既知化済み）のまま
    使うか、CHANGELOG の現行バージョンを手動で既知化する。

## 2026-07-16（Issue #260）ディープリサーチの Gemini API 経路を全廃止（native /deep-research → claude -p → DIY の三層に統一）

- **変更内容**:
  ディープリサーチのフォールバック連鎖から Gemini Deep Research Max（旧 Step 3.5）を撤去し、
  「① ネイティブ `/deep-research`（Skill 直接呼び出し）→ ② `claude -p` サブプロセス経由の
  `/deep-research`（`run_deep_research_workflow.py`）→ ③ DIY（WebSearch/WebFetch のウェブリサーチ）」の
  三層に統一した（飼い主決定: 外部 LLM API によるディープリサーチは今後一切行わない）。
  `tools/run_deep_research_gemini.py` を **削除**。`run_deep_research.py` は DIY 専用ランナー化
  （`--engine gemini` は受け付けない・`--fallback-reason` で発動記録を追記可能）。
  `research-runner` SKILL.md / reference.md・`modules.yaml`・`native_capabilities.json`・
  `research_schema.json`（engine enum から `gemini-deep-research-max` を除去）・
  `research-rules.md`・`dynamic-workflows-rules.md` を同方針に更新。
- **下流で必要な手動手順**:
  - `apply-to-repo.sh` の同期（`cp -a`）は **ファイル削除を下流へ伝播しない** ため、適用済み下流では
    再適用後に以下を実行して旧 Gemini エンジンを削除する:
    ```bash
    git rm tools/run_deep_research_gemini.py
    ```
  - 下流のスケジュールタスク・スキル・ドキュメントで `run_deep_research.py {ID} --engine gemini` を
    呼んでいる箇所があれば、`run_deep_research_workflow.py {ID}`（claude -p 経由の `/deep-research`）
    または DIY（`--engine diy` 相当＝引数なし）へ書き換える。
  - ディープリサーチ用途で `GEMINI_API_KEY` を環境変数供給していた下流は、その供給設定を撤去してよい
    （画像生成 MCP 等ディープリサーチ以外の用途で使っている場合は残す）。
  - 過去の生成物 `content/research/*_deep_research.json` に `engine=gemini-deep-research-max` が
    残っていても再検証・削除は不要（スキーマ enum は新規生成物にのみ適用される）。

## 2026-07-14（Issue #252）Intent Gate ルール新設（fable-method 反映・挙動変更前の spec/test/code 権威解決）

- **変更内容**:
  外部の [The Fable Method](https://github.com/Sahir619/fable-method)（MIT）を精査し、既存資産で埋まらない
  唯一の高価値要素「Intent Gate」を反映。`docs/rules/intent-gate-rules.md`（Warm 層）を新設し、
  挙動を変える編集の前に `INTENT: code does X / check expects Y / spec says Z` を確認して不一致を surface
  する規律と、権威順（ユーザー明示 > 仕様 > テスト > 現行コード）を SSOT 化した。
  `self-review-checklist.md` §0 に目視行を 1 行追加、`CLAUDE.md`（必読ルール タスク依存リスト +
  「やってはいけないこと」）へ参照を追記。L-113（confabulation）の姉妹則で、重複定義はしていない。
- **下流で必要な手動手順**:
  - `docs/rules/intent-gate-rules.md`・`self-review-checklist.md` は `apply-to-repo.sh` の再実行で自動同期される（手動不要）。
  - **`CLAUDE.md` は下流各リポジトリが独自管理するため自動同期されない**。Intent Gate をベース同等に効かせたい
    場合のみ、下流の `CLAUDE.md`「やってはいけないこと」へ「仕様と矛盾するテストを通すために正しいコードを
    黙って書き換えない（Intent Gate・権威順 ユーザー明示 > 仕様 > テスト > 現行コード・`docs/rules/intent-gate-rules.md`）」の
    1 行と、必読ルール（タスク依存）一覧へ `intent-gate-rules.md` の 1 行を手動でマージする（不要なら無視可）。

## 2026-07-14（Issue #242）コストテレメトリ永続化を telemetry/cost-data データブランチ直 push に変更（PR レーン廃止・cost_monthly の gitignore 化）

- **変更内容**:
  `content/analytics/cost_monthly/` を main で追跡しない方式に変更（gitignore 化）。永続化は
  `tools/commit_cost_telemetry.py` がテレメトリ専用データブランチ `telemetry/cost-data` へ
  1 日 1 回 plain git push で行う（gh 非依存・クラウドの 403 制約を受けない）。
  `chore/cost-telemetry-*` の専用 PR は廃止。Stop hook（`stop-git-check.sh` /
  `pre-pr-create-check.sh`）は同パスを未コミット検知から除外する。
- **下流で必要な手動手順**:
  ① `.gitignore` の `!content/analytics/cost_monthly/` 行（否定エントリ）が残っていれば削除する
  （apply-to-repo.sh は `.gitignore` を同期しないため手動。ベース側の新 `.gitignore` コメント参照）。
  ② main で cost_monthly が追跡されている場合は追跡解除して PR でマージする:
  `git rm -r --cached content/analytics/cost_monthly/ && git commit -m "chore: cost_monthly を追跡解除（base #242 追随）"`。
  ③ 過去データの移行は不要（新 `commit_cost_telemetry.py` が初回 push 時に origin/main の
  最終追跡版・履歴上の最終版を自動で種データにマージする）。
  ④ 参照方法の変更を周知: 月次コストは `git show origin/telemetry/cost-data:content/analytics/cost_monthly/YYYY-MM.json` で確認する。

## 2026-07-14（Issue #238）再同期レビュー由来のベース改善 3 点（project 引き継ぎ・自己参照 spec 隔離・auto-allow の settings 除外）

- **変更内容**:
  ① `scripts/merge_modules_yaml.py` が再適用時に `modules.yaml` の `project:` セクション
  （`name` / `repo` / `timezone`）の下流固有値も引き継ぐようになった（従来は `enabled:false` のみ）。
  再適用のたびに `project.name` が repo slug へ巻き戻る drift が解消される（自動同期で完結）。
  ② ベース自己参照専用の議論スペック `tools/discussion_specs/public_readiness_audit.json`
  （ベース自身の作業ディレクトリ絶対パス前提で下流実行不能）を `docs/discussion_specs_base_only/` へ隔離し、
  `modules.yaml` の `agent-teams` モジュール `tools:` 列挙からも除外した（下流へ配布されなくなる）。
  ③ `.claude/hooks/permission-request-auto-allow.sh` が `.claude/settings.json` /
  `.claude/settings.local.json` を auto-allow の対象から除外し、通常の権限フロー（ユーザー確認）に
  委ねるようになった（権限・フック配線 SSOT の自己書き換え面を塞ぐ・自動同期で完結）。
- **下流で必要な手動手順**: ②のみ手動対応が必要。`apply-to-repo.sh` の同期（`cp -a`）は
  **ファイル削除を下流へ伝播しない** ため、過去に本ベースを適用済みの下流には
  `tools/discussion_specs/public_readiness_audit.json` が孤立ファイルとして残り続ける。
  下流リポジトリで以下を実行して削除する（ベース自己参照専用のため下流では元々実行不能な spec）:
  ```bash
  git rm tools/discussion_specs/public_readiness_audit.json
  ```
  ①③は再適用のみで完結（手動対応不要）。①適用後は下流 `modules.yaml` の `project:` 値が
  再適用で保持されるため、下流側で `project.name` を手修正する運用は不要になる。

## 2026-07-13（Issue #227）クラウドで生存する gh コマンドの記述更新（gh auth status を認証判定に使わない）

- **変更内容**: 2026-07-13 実機再検証で、`gh auth status` が exit 0 のまま stderr に「GH_TOKEN invalid」
  失敗表示を出すことを確認。ベースの `CLAUDE.md`「gh CLI / GitHub 操作」節の「クラウドで生存するのは」行から
  `gh auth status` を外した（SSOT の `github-mcp-fallback-patterns.md`・`lessons-core.md` L-114 は自動同期）。
- **下流で必要な手動手順**: 下流リポジトリの `CLAUDE.md`（保護ファイル・自動同期されない）に同じ
  「クラウドで生存するのは: `gh api user` / `gh api rate_limit` / `gh auth status` …」行がある場合、
  ベースと同様に `gh auth status` を外し「（`gh auth status` は exit 0 でも失敗表示・認証判定に使わない）」を
  追記する。該当行が無ければ対応不要。

## 2026-07-12（Issue #211）orchestrator-directive 注入本文のオーバーライド機構ほか周知 3 点

- **変更内容**: ① `orchestrator-directive.sh` の注入本文を `.claude/orchestrator-directive.txt` で
  全文差し替え可能にした（ファイル不在時は従来の既定文言・4KB 上限）。② `pre-pr-create-check.sh` の
  Layer 1 リマインダーと self_review_check の Warning が `hookSpecificOutput.additionalContext` で
  Claude に届くようになった（従来の `systemMessage` は Claude に届いていなかった・#202 同型修正）。
  ③ `post-compact.sh` の stdout リマインダーを廃止し stderr ログに統一（PostCompact は stdout 注入
  非対応のため元々機能していなかった）
- **下流で必要な手動手順**: 通常は再適用のみで完結（自動同期）。`orchestrator-directive.sh` の
  注入本文（discussion-review スキル・agent-team-summary.md 前提の既定文言）を過去に直接編集して
  カスタマイズしていた下流のみ、再適用で上書きされる前に **カスタム本文を
  `.claude/orchestrator-directive.txt` へ移す**（以後は再適用で消えない）

## 2026-07-12（PR #203）daily-progress-rules.md を削除し user-notification-triage.md へ統合

- **変更内容**: `docs/rules/daily-progress-rules.md` を削除し、日次進捗レポートの構成を
  `docs/rules/user-notification-triage.md` §4.1 へ統合した（完了報告テンプレート重複の解消）
- **下流で必要な手動手順**: 自リポの `docs/rules/daily-progress-rules.md`（および
  `.claude/rules/daily-progress-rules.md` の symlink があればそれも）を手動削除する。
  同期はファイル削除を追従しないため、放置すると孤立ファイル化する。同ファイルを
  プロジェクト固有にカスタマイズしていた場合は、差分を `user-notification-triage.md` §4.1
  相当箇所へ移植してから削除する

## 2026-07-11（Issue #198 / PR #199）native-fallback 共通機構（Web 未提供機能の claude -p フォールバック）の新設

- **変更内容**: Web 未提供機能の native-first 判定 + `claude -p` フォールバック共通機構を追加
  （`tools/native_fallback.py`・`tools/native_capabilities.json`・`docs/rules/native-fallback-rules.md`・
  `modules.yaml` への配線）
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` のタスク依存ルール一覧に
  `native-fallback-rules.md` への参照を追加するか判断する（CLAUDE.md は保護対象のため
  自動反映されない）② 自リポ固有の Web ギャップ代替（isolation-by-design 対象）を棚卸しし、
  必要なら `tools/native_capabilities.local.json` オーバーレイを作成する（base の
  `native_capabilities.json` は同期で上書きされるため、フォーク固有差分は `.local.json` に書く）

## 2026-07-11（Issue #184 / PR #185 + #189）orchestrator-directive フック（高コストモデル検出時の専門チーム指示注入）の新設

- **変更内容**: 高コストモデル（Opus/Fable 系）検出時に「オーケストレーターとして専門チームを
  組成せよ」を UserPromptSubmit で自動注入する `orchestrator-directive.sh` を追加（#189 で
  正規表現検証・死にコード削除の堅牢化も実施）
- **下流で必要な手動手順**: `.claude/settings.json` を base 版に追従していない下流
  （`--keep-settings` 運用・独自 settings 管理）は、`UserPromptSubmit` フック配列の
  **guard → prompt-structuring → orchestrator-directive の順**（3 番目）で
  `orchestrator-directive.sh` を手動追加する（順序を誤ると二重バナー抑制が働かない。
  詳細はフックのヘッダーコメント参照）。トグル `CLAUDE_ORCHESTRATOR_DIRECTIVE` /
  判定正規表現 `CLAUDE_HIGH_COST_MODEL_RE` をプロジェクト方針に応じて設定するか判断する

## 2026-07-11（Issue #205）アップデート確認機構（base-sync-state マーカー + UPDATE NOTES）の導入

- **変更内容**: `apply-to-repo.sh` が適用完了時に `.claude/base-sync-state.json`
  （適用済みベースのコミット SHA・日時）を下流リポジトリへ記録し、再適用時に
  「前回適用以降の更新コミット一覧」と「本ノートの該当エントリ（手動手順が必要な更新）」を
  自動表示するようになった。`--check-updates` オプションで確認のみ（適用なし）も可能
- **下流で必要な手動手順**: なし（次回の適用で自動的にマーカーが作成される。
  マーカー `.claude/base-sync-state.json` はコミットして残すこと＝次回のアップデート確認の基準点になる）

## 2026-07-14（Issue #254 / PR #255）gh シム（クラウド 403 排除・GraphQL→REST 透過変換）の新設

- **変更内容**: クラウドの egress プロキシが repo スコープ REST を許可する挙動変化（2026-07-14 実測）を
  踏まえ、GraphQL 依存の gh 高レベルコマンドを REST へ透過変換する gh シム
  （`tools/gh_shim.py` + `.claude/bin/gh`）を追加。`session-start.sh` が `.claude/bin` を PATH 注入し、
  `stop-pr-check.sh` はクラウドでも REST で PR 存在を実検証、`generate_project_context.py` は
  クラウドで完全スナップショットを生成するようになった。SSOT
  （`github-mcp-fallback-patterns.md`・`lessons-core.md` L-114・CLAUDE.md の gh 節）も
  2026-07-14 実測マトリクスへ刷新
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` の gh 節（「クラウドでは MCP が一次経路」記述）を
  base 版（三層: シム + repo REST + MCP）に合わせて更新するか判断する（CLAUDE.md は保護対象のため
  自動反映されない）② `session-start.sh` を base 版に追従していない下流は、gh シム有効化ブロック
  （`.claude/bin` の PATH 注入・「gh シム有効化」コメント参照）を手動で移植する

## 2026-07-26（Issue #147）improvement-groomer を self-improvement-loop の整理モードへ統合

- **変更内容**: 改善 Issue 系スキルの責務境界を整理し、`improvement-groomer` スキルを削除して
  `self-improvement-loop` の **整理モード**（Step G-0〜G-5）として統合した（発見 / 整理 / 消化の 3 モード）。
  レーン境界の SSOT として `docs/rules/improvement-lane-map.md` を新設し、
  `retrospective` / `retro-try-handler` / `workflow-health-check` / `project-sync` の関係節を同ファイルの参照に置換。
  併せて `self-improvement-loop` 発見モードに Step 0.5（`workflow-health-check` 軽量版の実呼び出し）を追加し、
  「呼び出す」と書いてあるだけで実装がなかった連携を実装した。設計判断の記録は
  `docs/proposals/improvement-lane-consolidation.md`
- **下流で必要な手動手順**: ① 自リポの `.claude/skills/improvement-groomer/` を **手動削除** する
  （同期はファイル削除を追従しないため、放置すると孤立ファイル化し、統合後の
  `self-improvement-loop` とトリガーフレーズが衝突する）② 自リポの `CLAUDE.md` のスキル表から
  `improvement-groomer` 行を削除し、`self-improvement-loop` 行を 3 モード表記に更新する
  （CLAUDE.md は保護対象のため自動反映されない）③ 棚卸しをスケジュール実行に配線している下流は、
  起動フレーズを「`/self-improvement-loop --groom`（改善バックログを棚卸しして）」に差し替える。
  `tools/triage_improvements.py` は変更なしで存続するため差し替え不要

## 2026-07-26（Issue #323 / #324 / #325 / #326）Claude 5 世代向けコンテキストエンジニアリングの適用

- **変更内容**: Anthropic「The new rules of context engineering for Claude 5 generation models」を踏まえ、
  ① Hot 層（`.claude/rules/`）を 98,052 B → 65,867 B に再棚卸し（環境依存の障害カタログ L-079/L-080/L-101/L-106/L-114/L-117 を
  新設の `docs/rules/lessons/cloud-environment.md` へ Warm 降格し、Hot 側は症状ベースの索引 1 行に）、
  ② 同一規律の多重掲載を SSOT + 参照 1 行へ整理（応答スタイル＝ output style、完了報告＝ `completion-report-rules.md`、
  日時＝ `datetime-rules.md`、gh 403 ＝ `github-mcp-fallback-patterns.md`）、
  ③ `core-principles.md` CP-1 に「積極性は Issue 起票まで・コード変更は要求スコープ内」という衝突解決規則を追加、
  ④ `token-optimization-rules.md` の Hot 層予算を ~65KB / ~16,300 トークンへ改定（削減対象外の条件も明記）
- **下流で必要な手動手順**: ① 自リポの `CLAUDE.md` の「応答スタイル」「セッション完了報告」「日時表記」「gh CLI」各節を
  base 版の縮約形（SSOT 参照 1 行スタイル）に合わせるか判断する（**CLAUDE.md は保護対象のため自動反映されない**）。
  縮約しない場合も、規律そのものは Hot 層ルール側に残るため動作は変わらない
  ② 自リポで独自に `lessons-core.md` を運用している場合、環境障害カタログを Warm 降格するかを判断する
  （降格の判定軸は「その規律を機械強制しているハーネス / スキル / ツールが既にあるか」）
  ③ Hot 層に独自ルールを追加している下流は、新予算 ~65KB を基準に
  `session-compression-rules.md`「新規ルールファイル追加時の必須手順」の予算チェックを回す
  ④ **（#326）自リポの `CLAUDE.md` から「スキル一覧表」を削除するか判断する**。Claude Code 本体が
  `The following skills are available for use with the Skill tool:` として各スキルの `description` 付きで
  自動列挙するため完全に重複しており、表を持つ限りスキルの追加・削除のたびに手動追従が必要になる
  （#147 の `improvement-groomer` 削除時に実際に発生）。ただし **`description` に載らないプロジェクト固有の
  ルーティング規則**（例: ほぼ同名スキルが共存するときの既定経路）は表を消した後も残すこと
  ⑤ **（#326）「やってはいけないこと」から汎用コーディング規範を削除するか判断する**。
  「タスク外のファイルを変更しない」「要求外でリファクタしない」は Claude Code 本体のシステムプロンプトが
  既に指示しているため（`The requested scope is the deliverable` / `Write code that reads like the surrounding code`）、
  重ねて書くと矛盾解決コストだけが増える。**本体が言っていないプロジェクト固有の禁止事項**
  （`main` 直 push・L-077・Intent Gate・L-113・`settings.local.json` の env 禁止）は残すこと

## 2026-09-03（Issue #537 / #538）プラグイン配布経路の追加と `.claude-plugin/` 配布境界の変更

- **変更内容**: ① `.claude-plugin/marketplace.json` を新規追加し、公開リポジトリを Claude Code の
  プラグインマーケットプレイスとして機能させた（`claude plugin marketplace add kai-kou/claude-code-repository-base`）。
  ② `.claude-plugin/plugin.json` から `version` を削除（設定するとその文字列に pin され、bump するまで
  利用者に更新が届かない。省略すると git ソースの解決コミット SHA が版になる）。`skills` を `apply-base` に絞り、
  `agents` の宣言を廃止した（`owner.md` は判断基準の `session-sprint-rules.md` がプラグインでは配れず単体で機能しないため）。
  ③ `scripts/apply-to-repo.sh` の `SYNC_PATHS` を `.claude-plugin`（ディレクトリ）から `.claude-plugin/plugin.json`
  （単一ファイル）へ狭め、`REMOVE_PATHS` による 1 回限りの移行削除を追加した。
  ④ `scripts/bootstrap.sh` が clone 後に `.claude-plugin/marketplace.json` を削除するようにした。
- **下流で必要な手動手順**: ① **`.claude-plugin/marketplace.json` が自リポジトリに存在する場合は削除する**。
  これは「claude-code-base を配布するマーケットプレイス定義」であり、下流に残ると自リポジトリが
  claude-code-base の配布元を名乗ってしまう。**`apply-to-repo.sh` を再実行すれば `REMOVE_PATHS` が自動削除する**
  ため、通常は手動作業は不要（削除された場合は `- .claude-plugin/marketplace.json を削除` とログに出る）。
  ② 自リポジトリの `.claude-plugin/plugin.json` をプラグインとして配布している下流は、`version` フィールドの
  扱いを見直す（設定したまま bump しないと更新が届かない）。
  ③ 自リポジトリ独自に `.claude-plugin/` 配下へファイルを追加していた下流は、それが `SYNC_PATHS` の
  対象外になった（`plugin.json` のみ同期）ことを踏まえ、必要なら自リポジトリ側で管理する。
