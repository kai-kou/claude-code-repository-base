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
