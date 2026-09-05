# Warm 層 教訓 — 権限・auto モード（permissions）

権限判定（permission modes・`allow` / `ask` / `deny` ルール・classifier）に関する教訓を蓄積する。タスク依存で必要時に Read する（常駐しない）。

---

## L-127: auto モードでも read-only な `grep` が承認プロンプトを出す（v2.1.259 限定のリグレッション・恒久仕様ではない）（2026-09-03 初版 / 2026-09-04 訂正）

**パターン**: `defaultMode: "auto"` で稼働しているのに、`grep -rn "..." --include=*.md .` や `cd DIR; grep -n "..." 相対パス | head` のような **read-only な Bash コマンドが承認プロンプトになる**（下流リポジトリ複数で 2026-09-03〜04 に多発）。理由文は次の 2 種。

| ID | 型 | 理由文（逐語） |
|----|----|--------------|
| **P1** | ディレクトリ走査型 | `grep on '.' would read '<repo>/.env', which the deny rule Read(.env) covers; only you can approve running it anyway.` |
| **P2** | cd 後解決不能型 | `grep on 'a.md' after a cd would search a directory that cannot be determined here, and a Read() deny rule is configured; only you can approve running it anyway.` |

**根本原因（v2.1.259 と v2.1.260 の実バイナリ比較 + headless プローブで確定・2026-09-04）**: **Claude Code v2.1.259 だけが持っていた** `deniedPathInsideDirectory` チェックが直接原因。`Read(...)` の deny が **1 つでも** 設定されていると、`grep` / `egrep` / `fgrep` / `rg` / `diff` / `git` / `cp` / `mv` のディレクトリ走査（`-r` でオペランド無しなら `.`）と cd 後の相対パスを `ask` にし、`classifierApprovable:false` のため auto モードの classifier が上書きできず必ず人間のプロンプトになる。**v2.1.260 でこのコードは撤去された**（公式 CHANGELOG: "Reverted the 2.1.259 change applying `Read()` deny rules to Bash arguments; it denied `npm run build`"）。同じコマンド列は v2.1.260 で全件通過し、直接オペランドの deny（`cat .env` 等）は両バージョンで維持されている。

初版の診断「deny/ask の静的評価が classifier より先に決着する仕様どおりの挙動」は **誤り**。評価順（deny → ask → allow が classifier より先）の説明自体は公式仕様どおりだが、「`grep -r` が deny 対象を含むディレクトリを走査したら ask にする」という挙動は恒久仕様ではなく 1 バージョン限りのリグレッションだった。恒久仕様と一時的リグレッションを混同したことが、後述の「効かない対策」を機械強制まで進めた原因。

**効かなかった対策（実測済み・二度と回避策として書かない）**

| 試み | v2.1.259 での実測 | 理由 |
|------|-----------------|------|
| 再帰 grep に `--exclude='.env*' --exclude-dir=.git` を付ける（初版の対策 2・PR #547 でフック `grep_exclude_normalize.py` として機械強制） | **ask のまま**（P1 と同一文言） | オペランド抽出は `--exclude` / `--include` を値付きオプションとして読み飛ばすだけで、除外の意味を使わない | <!-- refcheck:ignore -->
| `--include='*.md'` で走査対象を絞る | **ask のまま** | 同上 |
| 絶対パスで直接実行する（初版の対策 1） | P2 は回避できるが、走査先に deny 一致があれば **P1 に転化して ask のまま** | ディレクトリ走査判定そのものは絶対パスでも行われる |

→ PR #547 のフック（`.claude/hooks/lib/grep_exclude_normalize.py` / `pre-tool-use-router.sh` の `_grep_deny_excludes` ブロック / `tools/test_grep_exclude_normalize.sh`）は **撤去済み**（効果ゼロのうえ「防御している」という誤った安心感を与えるため）。`.claude/settings.json` の `permissions.allow` の read-only コマンド列挙（`cat` / `head` / `grep` 等）は本件と無関係の恒常的最適化（複合コマンドは各サブコマンドが個別に allow 一致する必要がある仕様は不変）として維持する。 <!-- refcheck:ignore -->

**実測で有効だった唯一の回避策**: **ネイティブ `Grep` ツール** は v2.1.259 / v2.1.260 の両方で deny 対象を **黙って除外** し、プロンプトを出さない（ripgrep に deny 由来の除外を渡す実装）。

**行動規範（訂正版）**

1. **バージョン固有と疑われる権限プロンプトの増加を見つけたら、恒久的なハーネス回避策を先に作らない**。順序は ① `bash tools/probe_permission_prompts.sh` で現行バージョンの実挙動を確認（exit 2 = 陽性対照が壊れている＝環境要因、exit 1 = 走査系が ask/deny＝リグレッション）② 公式 CHANGELOG（`raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md`）で該当変更が revert / fix 済みかを確認 ③ 未 revert なら `[CC-Sync][破壊的変更]` Issue として spec-sync レーンに乗せ、一時措置は小さく・恒久ルール化しない ④ 次バージョンで revert されたら措置を撤回する。
2. **`permissions.deny` に `Read(...)` が 1 つでもあるリポジトリで、複数ファイルにまたがる再帰検索をするときは、Bash の `grep -r` / `rg` よりネイティブ `Grep` ツールを優先する**（狭い例外。auto モードの「Bash を使え」指示が代替として挙げているのは Read / Edit / Write ツールであり、Grep / Glob には触れていない。単一ファイルの確認・パイプ処理は従来どおり Bash でよい）。ask が出てからの事後対応としても同じ。
3. 復旧は **新しいセッションを開始して `claude --version` が 2.1.260 以上であることを確認する**（コンテナのバージョンは起動時に固定される。事象は Anthropic 側の revert で新コンテナから解消済み。実害を止めるのはベース側の配布ではない）。
4. **deny ルールの削除・緩和で回避しない**（P2 は deny の存在だけで発火するので粒度調整では防げず、削除は保護の無効化）。Python / Node スクリプト経由の間接読み取りも同様に禁止。

**再発防止の機械化**: `tools/probe_permission_prompts.sh` が、リポジトリ外の一時ディレクトリに deny 設定つきラボを作り、`claude -p --permission-mode auto` で固定コマンド列（陽性対照 `cat .env` + 走査系 `grep -rn .` / `--include` / `cd` 複合 / `rg` + ネイティブ Grep）を投入して `permission_denials` を機械判定する（`-p` では ask が終端＝自動 deny になる仕様を利用。陽性対照が deny にならなければ exit 2 で fail-closed）。spec-sync レーンは **新バージョンを検知したら分類結果（破壊的 / 新機能 / その他）に関わらずこれを実行** する（CHANGELOG のキーワード辞書では "Reverted ..." 行を拾えず「その他」に落ちて #557 で影響なしと記録された見落としへの対策。`config/claude_code_spec_sync.yaml` の `breaking_keywords` にも `revert` を追加した）。

**罠（維持）**

- **`--permission-prompts none`（v2.1.259 新設）は「承認」ではなく「自動 deny」**。denial を通常の失敗と区別する検知なしに無人ルーティンへ入れると「見える停止」が「見えない誤動作」になる
- **`defaultMode: "auto"` はユーザー設定（`~/.claude/settings.json`）でのみ有効**。プロジェクトの `.claude/settings.json` に書いても無視される
- **全アクションが一斉にプロンプトへ戻ったらサーキットブレーカー**（classifier が 3 連続 or 累計 20 ブロックで auto を一時停止）。本件（deny/ask 段の判定）はこれに該当しない
- **セッション途中で apply-base してもフックは再読込されない**（フックは起動時スナップショット・公式仕様）。フック変更の効果を見るには新セッションが要る
- **`~/.claude.json` の trust dialog 未承認ディレクトリでは `.claude/settings.json` の `allow` が無視される**（`Ignoring N permissions.allow entries ... this workspace has not been trusted`）。プローブはこれを自動設定し終了時に元へ戻す

**時系列（参考）**: v2.1.251（Grep/Glob の symlink 経由 deny 適用）→ v2.1.257（`<` リダイレクト・`permissions.ask` 複合コマンド）→ v2.1.259（Bash 引数への Read deny 適用 + ディレクトリ走査の ask 化）→ v2.1.260（v2.1.259 の Bash 引数適用を revert）。同一領域で連続して調整されており、次の再導入がいつ来るか読めない。だから検知はプローブに、回避は行動規範 2 に委ねる。

**保持理由**: 「1 バージョン限りの挙動を恒久仕様と誤診して機械強制まで進める」失敗は、権限・フック・設定のどの領域でも再発しうる。訂正の経緯ごと Warm 層に残す。議論記録: `content/discussions/auto-mode-prompt-root-cause-20260904/`。

---

## L-128: `.env.example` 等テンプレートの「ホワイトリストで通す」は permissions.deny の前に必ず負ける（2026-09-03・#549）

**パターン**: `.claude/hooks/pre-tool-use-router.sh` の `_sfa_env_access` が `.env.example` / `.env.sample` /
`.env.template` / `.env.dist` を明示的に許可するホワイトリストを持っていたが、`.claude/settings.json` の
`permissions.deny`（`Read(.env.*)`）がそれより手前で判定を確定させるため、**ホワイトリストは実際には一度も
機能していなかった**（PR #547 の Layer 1 セルフレビューで発覚）。

**根本原因（公式ドキュメントで確認済み・[Configure permissions](https://code.claude.com/docs/en/permissions)）**:
`deny` → `ask` → `allow` の順で評価され、**最初にマッチした段で決着し、ルールの具体性は順序に影響しない**
（"rule specificity doesn't change the order"）。つまり `Read(.env.*)` という広い deny が一致した時点で、
どれだけ具体的な allow（`.env.example` だけを許可する等）を後ろに置いても **原理的に上書きできない**。
`permissions.deny` / `allow` の glob には否定（`!pattern` 等の除外）構文も存在しない。

**「deny を実ファイル名の列挙に絞る」代替も採らない理由**: `.env.local` 等の既知の実ファイル名だけを
`permissions.deny` に列挙し `.env.*` の広いパターンをやめれば、`.env.example` 等は deny に一致しなくなり
読めるようにはなる。しかし `pre-tool-use-router.sh` の第 2 層ガードは **Bash 経由アクセスにしか発火しない**
（`settings.json` の `PreToolUse` matcher は `Bash|mcp__github__create_pull_request` のみで、ネイティブ
`Read` ツールは対象外）。したがって列挙から漏れた実 `.env` 派生ファイル（例: `.env.staging2`）は、
ネイティブ `Read` ツール経由では **どちらの層にも守られず無防備に読めてしまう**。deny の列挙をどれだけ
充実させても「新しい命名の実ファイルが列挙から漏れる」リスクは構造的に残るため、この代替案は採らない。

**採用した対策**: ホワイトリストを撤去し、`_sfa_env_access` を `permissions.deny` と同じ「`.env`/`.env.*` は
テンプレート名も含めて一律ブロック」に揃えた（両層一致）。実挙動は変わらない（`.env.example` は
`permissions.deny` により従来から読めていなかった）。設定項目名を確認したい用途は、テンプレートを
`.env.example` 以外の非 `.env` 系ファイル名（例: `docs/` 配下の Markdown）で提供する運用でカバーする。

**判定基準**: 「deny 側の広いパターンに一致する対象を、別レイヤーの allow/whitelist だけで部分的に
通そうとしていないか？」→ Yes なら、そのホワイトリストは機能していない可能性が高い（deny は具体性に
関わらず常に先勝ちする）。allow 例外を作りたいときは、まず deny 側のパターン自体を狭め、かつ
「deny を狭めた分の穴を、Bash 以外の経路（ネイティブ Read/Edit/Write）でも別レイヤーが塞げるか」を
必ず確認する。

**保持理由**: 「2 層あるから安全」という思い込みが、実際には片方が死んでいる非対称を見逃す典型例。
allow/deny の評価順とレイヤー適用範囲（Bash 限定 vs 全ツール）は他の機密ファイルガードにも波及する
恒久的な設計制約のため、Warm 層に常駐させる。

---

## L-129: 無人ルーティンが「作業領域の外を触る Bash」の承認プロンプトで無限停止する（2026-09-05・#578）

**症状**: scheduled trigger（無人ルーティン）のセッションが承認プロンプトを出したまま数時間停止する。誰も承認しないため、ルーティンはその回の処理を一切終えられない。下流 blog-dispatch ルーティンで観測された 2 例（いずれも Bash ツール）:

| # | コマンド（要約） | プロンプトの表示 |
|---|----------------|----------------|
| 1 | `WORK=/tmp/skill-doctor-demo; rm -rf $WORK; mkdir -p $WORK/.claude; cp -r <repo>/.claude/skills $WORK/...` | `Prepare isolated skill-doctor demo dir` の run 許可 |
| 2 | セッション scratchpad を作ったうえで、ホーム配下 `~/.claude/projects/<project>/<session>/tool-results/<id>.txt` を `cp` してから `python3 -c` で解析 | `Claude requested permissions to edit ~/.claude/projects/...` |

**根本原因（実測で確定・3 層）**

1. **クラウド実行環境では Bash サンドボックスが起動できない**。実測: `command -v bwrap` = MISSING / `command -v sandbox-exec` = MISSING / `/proc/self/status` の `Seccomp: 0`。したがって `.claude/settings.json` の `sandbox.enabled: true`・`autoAllowBashIfSandboxed: true` はクラウドでは **無効**（ローカル専用の設定）。公式仕様上サンドボックスが既定で書き込みを許すのは「作業ディレクトリ / セッション一時ディレクトリ / `additionalDirectories`」で、その外は "Blocked access: cannot modify files outside ... without explicit permission" と明記されている。
2. **サンドボックスが無い以上、Bash の可否は `permissions.*` の静的ルールと auto モードの classifier だけで決まる**。`permissions.allow` に `mkdir` / `cp` / `rm` / リダイレクト書き込みは無く（危険なので載せるべきでもない）、classifier は作業ツリー外への書き込み・削除を自動承認しない。headless プローブ（`claude -p --permission-mode auto`）で実測: 作業ツリー外への `mkdir` + リダイレクト書き込み・`rm -rf` は `permission_denials` に記録される（= 対話なら承認プロンプト）。作業ディレクトリ内・セッション scratchpad 配下は記録されない。
3. **`PermissionRequest` フックの自動承認が Bash に効いていなかった**。`permission-request-auto-allow.sh` はホーム配下を含む `.claude` パスを自動承認するが、`settings.json` の matcher が `Read|Write|Edit|NotebookEdit` のため **Bash 経由のアクセスは射程外**。一方 auto モードのシステムプロンプトは「できる仕事は Bash で行え」と指示するため、ネイティブツールなら通る操作が Bash 経由だとプロンプトになる **非対称** が生まれていた（例 2 がこれ）。

**対策（採用）**

- **ハーネス（機械強制）**: `.claude/hooks/lib/workspace_write_guard.py` を `pre-tool-use-router.sh` から呼び、① 作業ディレクトリ・セッション一時領域の外への書き込み / 削除、② ホーム配下の `.claude` 領域への Bash アクセス、を **プロンプトになる前に exit 2 で差し戻す**。ブロックはツール失敗として Claude に返るため、無人セッションでも停止せず代替経路へ自己修正できる（承認待ちは「見える停止」ですらなく、無人では誰にも見えない）。判定はシェルの実挙動に寄せてある（Layer 1 セルフレビューで実測された取りこぼしを全て塞いだ結果）:

  | 解析上の論点 | 扱い |
  |---|---|
  | セグメント分割 | クォートを尊重した shlex トークン化（`punctuation_chars`）。生文字列を正規表現で割ると、クォート内に `&` を含む URL 引数などでコマンドが分断され解析が丸ごと落ちる |
  | 変数経由のパス | 同一コマンド文字列内の `NAME=value` を展開する（例 1 の捕捉に必須） |
  | heredoc | 本文は解析対象から除く（文書中の例示パスでの誤ブロック防止・導入直後に実発生）。同一行の複数 heredoc に対応し、**終端が見つからないときは読み飛ばした行を解析対象へ戻す**（fail-open だと終端漏れ以降の実コマンドが不可視になる） |
  | 書き込み先の抽出 | 位置引数だけでなく `-t DIR` / `--target-directory=DIR`、`curl -o` / `--output-dir`、`wget -O` / `-P`、`sed -i` の対象、`dd of=`、fd 付き・noclobber リダイレクト（`2>` / `&>` / `>|`）を対象にする |
  | 擬似デバイス | `/dev/` 配下と `/proc/<pid>/fd/` は書き込み対象から除く（`2>` で捨てる定型が止まる。導入直後に実発生） |
  | 前置きコマンド | `sudo` / `env` / `nice` / `timeout` 等のラッパーを 1 段読み飛ばしてから実コマンドを判定する |
  | `cd` の効果 | セグメントをまたいで基点を引き継ぐ（作業ツリー外へ移動してからの相対パス削除を取りこぼさない）。解決できない `cd` 先の後は相対パスを判定不能として素通りさせる |
  | セッション一時領域 | `/tmp/claude-<N>/<project>/<session-id>/` を **session_id まで一致** させる。緩いプレフィックス一致だと他セッションの scratchpad の削除まで安全扱いになる |
  | symlink | `realpath` で解決してから判定する（作業ツリー内のリンクが外を指すケース） |

  回帰テストは `bash tools/test_workspace_write_guard.sh`（39 ケース）と、ガード単体の `python3 .claude/hooks/lib/workspace_write_guard.py --self-test`。機密ファイルガードの回帰テストは同じ router を通すため、本ガードをトグルで切って走らせる（検証したい機密判定が別ガードのブロックでマスクされるのを防ぐ）。

  **読み取りまでブロックする根拠**（レビュー指摘への回答）: ホーム配下 `.claude` は書き込みだけでなく **読み取りもプロンプトになる**。headless プローブで `cat <ホーム配下 .claude のファイル> | head -3` と `grep -c . <同>` を投入したところ、両方とも `permission_denials` に記録された（拒否理由の文面も "tries to read a file outside the allowed working directory"）。ただしこの実測ラボは `permissions.allow` を持たないため、本ベースの `Bash(cat:*)` / `Bash(grep:*)` が allow 側で先に決着する可能性は残る（未確認）。**無人停止のコスト（誰も承認せず無限待ち）と代替のコスト（ネイティブ Read / Grep へ切り替える 1 往復）が非対称** なので、読み取りもブロック側に倒している。
- **行動規範**: 一時作業はセッション scratchpad（システムプロンプトが提示するパス）かリポジトリ内で行う。ツール結果の persisted output（ホーム配下 `.claude/projects/.../tool-results/`）は **ネイティブ Read / Grep で読む**（`PermissionRequest` フックが自動承認する）。Bash で複製しない。

**採らなかった案と理由**

| 案 | 不採用の理由 |
|----|------------|
| `PermissionRequest` の matcher に `Bash` を足して自動承認する | `PermissionRequest` は公式仕様上 Bash でも発火するが、任意の Bash を自動承認するのは実質 `bypassPermissions` と同じで、承認レイヤーそのものを無効化する |
| `permissions.allow` に `Bash(mkdir:*)` / `Bash(cp:*)` / `Bash(rm:*)` を足す | allow はコマンド名前方一致でパスを制御できず、作業ツリー外への破壊的操作まで一律に許してしまう。複合コマンドは各サブコマンドが個別に allow 一致する必要があるため、破壊的コマンドが混ざれば結局止まる |
| `sandbox.filesystem.allowWrite` で外部パスを許可する | クラウドではサンドボックス自体が起動しない（根本原因 1）ため効果ゼロ。ローカルでも「作業ツリー外に書く」運用を追認することになる |

**残余リスク（ハーネスで塞げない部分）**: `python3 -c` のような任意コード経由の外部書き込みは字面から判定できない（`pre-tool-use-router.sh` の機密ファイルガードと同じ限界）。また classifier の判断はモデル・バージョン依存でぶれるため、ガードが想定しない別種のコマンドが承認プロンプトに落ちる可能性は残る。ルーティン自体の permission mode（`create_trigger` の `permission_mode`）を緩めるのは承認レイヤーを外す判断であり、ハーネス側からは行わない。

**判定基準**: 「このコマンドが書き込む / 消す先は、作業ディレクトリかセッション scratchpad の中か？」→ No なら、無人セッションでは承認待ちで止まると考える。

**保持理由**: 無人ルーティンの無限停止は「失敗せずに何も進まない」最も気づきにくい停止形態で、クラウド運用のあるプロジェクト全てで再発しうる。サンドボックス設定がクラウドで無効という前提も、設定を読んだだけでは分からず繰り返し誤解される。
