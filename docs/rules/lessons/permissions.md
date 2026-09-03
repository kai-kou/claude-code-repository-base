# Warm 層 教訓 — 権限・auto モード（permissions）

権限判定（permission modes・`allow` / `ask` / `deny` ルール・classifier）に関する教訓を蓄積する。タスク依存で必要時に Read する（常駐しない）。

---

## L-127: auto モードでも read-only な `grep` が承認プロンプトを出す（deny/ask の静的評価が classifier より先に決着する）（2026-09-03）

**パターン**: `defaultMode: "auto"` で稼働しているのに、`grep -rn "..." .` のような **read-only なはずの Bash コマンドが承認プロンプトを出す**。「auto モードが壊れた」「classifier が厳格化された」と誤診しやすい（下流リポジトリでの実測）。

**根本原因（仕様どおりの挙動）**: 権限判定には決定順があり、**最初にマッチした段で決着して以降には進まない**（公式ドキュメント `code.claude.com/docs/en/permission-modes` の「How the classifier evaluates actions」）。

```
① allow / ask / deny ルールの静的評価  ← ここで決着したら ② 以降に進まない
② read-only アクション・作業ディレクトリ内の編集を自動承認
③ それ以外を classifier が審査
④ classifier がブロックしたら Claude に理由が返り、代替手段を試す
```

`grep` が read-only として自動承認されるのは ② の話だが、**① が先に評価される**。`deny` / `ask` ルールは `bypassPermissions` を含む全モードでブロックし、**classifier はこれを上書きできない**。したがってこのプロンプトは auto モードの不具合ではなく、**仕様どおりの安全側フォールバック** である。

**発火する 2 パターン（対策が異なるので必ず区別する）**

| ID | 型 | 例 | 理由文 |
|----|----|----|--------|
| **P1** | 確実一致型 | `grep -rn "..." .` — 走査範囲に deny 対象（例 `.env`）が確実に含まれる | `would read` |
| **P2** | 解決不能型 | `cd DIR; grep -n "..." 相対パス` — `cd` 後の検索先が静的に決定できず deny 一致判定が unknown になる | `cannot be determined` |

**時期（CHANGELOG の実取得で確認済み・日付記載はなし）**: deny ルールの **適用漏れを塞ぐ修正** が連続投入されたため、既存の deny 設定のままでプロンプトだけが増えたように見える。classifier の厳格化ではない。

- **v2.1.251**: `Grep` / `Glob` が symlink 経由の探索パスに Read deny を適用していなかった不具合を修正
- **v2.1.257**: `< file` リダイレクト・`tac` / `egrep` への Read/Edit deny 適用漏れ、`permissions.ask` が複合コマンド・サブシェル内でスキップされていた不具合を修正
- **v2.1.259**: オプション値として渡されたファイル・`git diff` / `git grep` のオペランド・`cd DIR && cat FILE` 複合への Read deny 適用漏れを修正。あわせて `grep -r` / `cp -r` のディレクトリ経由到達を `ask` 化

**対策（行動規範・この 2 つを守る）**

1. **Bash では `cd DIR; cmd 相対パス` の複合を書かず、絶対パスで直接実行する**（P2 に有効）
2. **再帰 grep には `--exclude=.env*` `--exclude-dir=.git` 等を付け、deny 対象を走査範囲から明示除外する**（P1 に有効。**P1 は絶対パス化では直らない**）

補助（設定側）: 単一箇所にしか存在しない既知の秘密ファイルは deny をアンカー化してよい（`Read(.env)` → `Read(./.env)`）。ただし `**/*.pem` `**/id_rsa` `**/.aws/**` のように **複数階層に出現しうる汎用パターンは緩めない**。

**本ベースでの機械強制（下流への配布経路つき）**

配布は `.claude/settings.json` と `.claude/hooks/` を運ぶ既存の一方向同期に乗る（開発リポジトリ → `publish-sync` → 公開リポジトリ → 下流での `apply-base` / `scripts/apply-to-repo.sh`）。**下流に届いたかを能動的に確認する経路は無い** ので、公開側への反映が漏れるとこの機械強制は下流に存在しないままになる。反映漏れは `python3 tools/check_publish_drift.py` が検知し、反映できないセッションは `[publish-sync]` Issue に記録して次のセッションが回収する（`pr-review-flow-summary.md`）。下流で承認プロンプトが減らないときは、まず下流の `.claude/hooks/lib/grep_exclude_normalize.py` の有無を見る（無ければ配布が届いていない）。

**機械化されているのは対策 2 だけ** である。対策 1（絶対パスで直接実行する）は行動規範のままで、`cd` 複合コマンドを自動で書き換える機構は無い（意味が変わる書き換えになるため入れていない）。

| 層 | 実体 | 効果 |
|----|------|------|
| PreToolUse フック | `.claude/hooks/pre-tool-use-router.sh` + `.claude/hooks/lib/grep_exclude_normalize.py` | `grep -r` / `-R` / `--recursive` に `--exclude` 系が未指定なら、公式仕様の `updatedInput` で deny 対象の除外オプションを自動付与する（P1 を発火前に消す）。除外パターンは `settings.json` の `permissions.deny` から動的生成する（設定を足したときの更新漏れを作らない） |
| 権限設定 | `.claude/settings.json` の `permissions.allow` | `cat` / `head` / `ls` / `stat` 等を列挙。**複合コマンドは各サブコマンドが個別に allow へ一致する必要がある**（公式 permissions: "A rule must match each subcommand independently"）ため、`cat A; python3 B` のような複合が classifier 送りで拒否されるのを防ぐ |

**書き換えの適用範囲（誤爆を避けるための制限）**: 対象は **実行位置にある `grep`** だけで、ヒアドキュメント本文・引用符内の文字列・コマンド置換の内側は書き換えない（素朴な文字列置換にすると `cat > script.sh <<EOF … grep -rn … EOF` で **書き出されるファイルの中身が化ける**）。`git grep` は先頭語が違うので対象外。**`rg`（ripgrep）は未対応** — 既定で再帰する一方 `--glob '!pattern'` と除外構文が異なり、grep 用の実装を転用できないため。

**`allow` に足してよいコマンドの基準（セキュリティレビューの結論）**: `deny` は最優先で評価されるので `Bash(cat:*)` を allow しても `cat .env` は `Read(.env)` の deny で止まる。**ただし `deny` の `Read(...)` は cwd アンカー** で、`~/.ssh/id_rsa` のような cwd 外の実パスは守らない。したがって allow に載せてよいのは次のどちらかを満たすものに限る。

- 同ルーターの機密ファイルガード（`_sfa_cmds` / `_sfa_search_cmds`）が第 2 層として見張っているコマンド（`cat` / `head` / `tail` / `grep` / `rg` 等）
- **ファイル内容を出力しない** コマンド（`ls` / `wc` / `stat` / `file` / `which` / `git ls-files` / `git rev-parse` 等）

内容を出力できるのにガード対象外のコマンド（`jq` / `diff` / `cut` / `git show` / `git blame`）を allow に載せてはいけない。載せると classifier の審査すら通らなくなり、`jq -R . ~/.aws/credentials` のような cwd 外の秘密読み取りが無検問で通る。`-o` で書き込める `sort`、リダイレクトの起点になりやすい `echo` / `printf` も同様に外す。

**`grep` / `rg` を allow に載せるなら第 2 層の拡張とセットにする**: いったんセキュリティ指摘に従って両者を allow から外したところ、フックが書き換えた再帰 grep が今度は承認プロンプト側に回り、**本来の目的（承認を出さない）と逆行した**（本セッションで実測）。そこで第 2 層のトークン抽出に検索コマンドを加え、**`/` か `~` を含むパス様トークンだけ** を判定対象にした。第 2 層の役目は cwd 外の実パスを塞ぐことなので、これで `grep -n "" ~/.ssh/id_rsa` を止めつつ `grep -rn "id_rsa" docs/` のような検索語の誤ブロックを避けられる。**allow から外すのは「守れないから」であって、守れるようにしたなら載せてよい。**

> 関連: v2.1.257 で auto モードに「作業ディレクトリ外の初回ファイル読み取り前の一度きりプロンプト」と `permissions.blockReadsOutsideWorkingDirectories` が入った。cwd 外読み取りを設定側で塞ぎたいならこれを使う（本ベースは未採用）。

**❌ 禁止 / ✅ 推奨**

```
❌ cd src; grep -n "foo" .                                   # P2: 検索先が静的解決できず ask になる
✅ grep -n "foo" /abs/path/src/                              # 絶対パスで直接実行する
❌ grep -rn "foo" .                                          # P1: 走査範囲に deny 対象が含まれる
✅ grep -rn --exclude='.env*' --exclude-dir=.git "foo" /abs/path/
❌ deny ルールを削除する / Python・Node スクリプト経由で間接的に読む   # 保護の無効化
```

**罠（必ず踏まえること）**

- **`--permission-prompts none`（v2.1.259 新設）は「承認」ではなく「自動 deny」**。denial を通常の失敗と区別する検知ロジックなしに単独導入すると、無人ルーティンでは「見える停止」を「見えない誤動作」に変えるだけで、かえって悪化しうる
- **deny ルールの削除、および Python / Node スクリプト経由の間接読み取りによる迂回は禁止**。deny は Claude Code が認識できる Bash のファイルコマンドにしか効かないため技術的には通るが、それは保護の無効化にほかならない
- **`defaultMode: "auto"` はユーザー設定（`~/.claude/settings.json`）でのみ有効**。プロジェクトの `.claude/settings.json` に書いても無視される
- **全アクションが一斉にプロンプトへ戻ったらサーキットブレーカー**（3 連続 or 累計 20 ブロックで auto を一時停止）。`/permissions` の Recently denied で確認し、`r` で手動承認リトライする。プロンプトではなく **即時拒否** なら PreToolUse フックであり別レイヤーの問題

**未検証（断定しない）**

- 組み込み `Grep` ツールが deny 対象を含むディレクトリでプロンプトを出すのか、黙って除外するのか
- `--exclude=.env*` が v2.1.259 の `ask` 条件を実際に回避できるか
- `--permission-prompts none` による自動 deny が `/permissions` の Recently denied に記録されるか
