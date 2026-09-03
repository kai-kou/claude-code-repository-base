# 既存リポジトリへルール・スキル・ハーネスを適用する（ワンコマンド）

> **目的**: 他リポジトリで毎回手動指示していた
> 「gh で `kai-kou/claude-code-repository-base` を参照し、ルール・スキル定義・ハーネスを全部適用して」
> を **1 コマンド** に置き換える。`scripts/apply-to-repo.sh` がベースを取得して対象リポジトリへ展開する。

`scripts/bootstrap.sh` が「ベースを clone してから新規プロジェクトに馴染ませる」初期化用なのに対し、
本スクリプトは **逆方向 ——「既存リポジトリ側で叩くと、ベースの設定が取り込まれる」適用ツール** である。

---

## TL;DR（対象リポジトリのルートで実行）

```bash
# A. リモートから直接（最も手軽。git だけで動く）
curl -fsSL https://raw.githubusercontent.com/kai-kou/claude-code-repository-base/main/scripts/apply-to-repo.sh | bash

# B. オプションを付けたい場合（ローカルにスクリプトを置いて実行）
curl -fsSLO https://raw.githubusercontent.com/kai-kou/claude-code-repository-base/main/scripts/apply-to-repo.sh
bash apply-to-repo.sh --tz Asia/Tokyo --prune
```

実行すると以下が対象リポジトリに展開される:

- **ルール**: `docs/rules/`（実体）+ `.claude/rules/`（常駐 symlink を自動再生成）
- **スキル定義**: `.claude/skills/`
- **ハーネス**: `.claude/hooks/` + `.claude/settings.json`（フック登録）
- **エージェント / コマンド**: `.claude/agents/` / `.claude/commands/`
- **ツール / 補助**: `tools/` / `scripts/` / `modules.yaml` / `.mcp.json` / `.claude-plugin/`

対象リポジトリの slug は `git remote origin` から自動判定し、プレースホルダ（`__OWNER__/__REPO__` 等）を置換する。

---

## オプション

| オプション | 既定 | 説明 |
|-----------|------|------|
| `--base owner/repo` | `kai-kou/claude-code-repository-base` | ベースリポジトリ |
| `--ref <branch\|tag\|sha>` | `main` | 取得する ref |
| `--repo owner/repo` | git remote から自動判定 | 対象リポジトリ slug（プレースホルダ置換用） |
| `--name "..."` | リポジトリ名 | プロジェクト名（`{{PROJECT_NAME}}` 置換） |
| `--desc "..."` | プロジェクト名 | プロジェクト説明（`{{PROJECT_DESCRIPTION}}` 置換） |
| `--tz Asia/Tokyo` | （空） | タイムゾーン |
| `--prune` | off | `modules.yaml` で `enabled:false` のモジュール資産を除去 |
| `--overwrite-project` | off | `CLAUDE.md` / `docs/project-mission.md` も上書き（既定は保護） |
| `--keep-settings` | off | `.claude/settings.json` を上書きしない（既定はバックアップして導入） |
| `--check-updates` | off | 適用せず、前回適用時点からのアップデート内容だけ表示する |
| `--dry-run` | off | コピーせず適用対象を表示するだけ（どのファイルがマージ・要確認になるか事前に見える） |
| `--no-merge` | off | 3 方向マージを行わず全ファイルを無条件上書きする（旧来の挙動。マージ機構に問題が出たときの退避経路） |

---

## 何が保護され、何が上書きされるか

| 区分 | 挙動 |
|------|------|
| ルール / スキル / ハーネス / ツール（`docs/rules`・`.claude/{rules,hooks,skills,agents,output-styles,commands}`・`tools`・`scripts`・`modules.yaml`・`.mcp.json`・`.claude-plugin`）と `.claude/settings.json` | **祖先つき 3 方向マージで同期**（下記）。ベース側が更新していないファイルには触らないため、下流の変更が消えない |
| `.claude/settings.json` | 上と同じ経路。加えて初回のみ `.claude/settings.json.pre-base.bak` に退避する（`--keep-settings` で同期自体を止められるが、ベースのフック更新も届かなくなる） |
| ベースに存在しないファイル（下流が独自に足したルール・スキル・ツール） | **一切触らない**（同期はベース側にあるファイルだけを対象にするため） |
| `CLAUDE.md` / `docs/project-mission.md` | **プロジェクト固有のため既定では上書きしない**。既存があれば維持し、ベース版を `*.base` として横に配置（差分を手動で取り込む）。`--overwrite-project` で上書き |

### 同期の 4 分岐（下流の変更が消えない仕組み）

`.claude/base-sync-state.json` に記録した **前回適用したベースの SHA** を祖先として、ファイルごとに振り分ける。

| 状況 | 挙動 |
|------|------|
| ベース側が前回適用から変更していない | **触らない**（下流の変更をそのまま保つ） |
| ベース側が変更・下流は祖先のまま | ベース最新で更新する |
| 両側が変更 | **3 方向マージ** して採用する（`tools/merge_three_way.py`） |
| 衝突した / 検証に落ちた / 祖先が使えない | **下流のファイルを温存** し、ベース最新を `<path>.base-latest` として横に置く |
| 前回の `.base-latest` が未解決のまま残っている | マージせず `.base-latest` をベース最新へ更新し、**毎回「要確認」として再報告** する |

`modules.yaml` も上記の 4 分岐にそのまま乗る（専用の意味マージャは廃止済み。実測検証は Issue #509）。
下流の `enabled: false` / `project:` 値はベース側が無変更なら触られず、両側が変更した場合も
3 方向マージが下流の変更行をそのまま保持する。

- **衝突マーカーはワークツリーに書かれない**。マージがクリーンで、かつ検証（衝突マーカー・JSON 構文・
  **重複キー**）を通ったときだけ採用する。壊れた `settings.json` でセッションが起動しなくなる、
  ルールファイルがマーカー付きのまま規範として読まれる、といった事故が構造的に起きない。
- 適用の最後に **同期サマリー**（触れず / 更新 / マージ / 要確認の件数と該当ファイル）が表示される。
  マージしたファイルはコミット前に `git diff` で確認する。`要確認` は `diff <path> <path>.base-latest`
  で取り込み、済んだら `.base-latest` を削除する。
- 初回適用（マーカーなし）・ベース切替・force-push で祖先に到達できないときは、従来どおりの上書き同期に
  自動で退避する（サマリーに「祖先: 未使用」と表示される）。

### 下流独自のルールは `docs/rules/local/` に置く

ベース管理下の `docs/rules/*.md` に独自節を直接足すと、ベース側が同じファイルを更新した回に
3 方向マージか要確認扱いになり、確認の手間が残る。**独自ルールは `docs/rules/local/{同名}-local.md`
のような新規ファイルに分離する**のが推奨（ベースに存在しないファイルは同期対象外なので常に無傷）。
常駐させたい場合は `.claude/rules/` へ下流側で symlink する。
既存ルールの本文そのものを書き換えたい場合だけは分離できないので、3 方向マージの衝突検出に委ねる。

> **`*.base` の扱い**: `CLAUDE.md.base` は応答スタイル・PR 自律化方針・大原則参照などの雛形。
> 既存 `CLAUDE.md` に必要な節（応答スタイル / 必読ルール表 / PR 自律化）をマージする。
> `docs/project-mission.md.base` はミッション・KPI の雛形。

---

## 再実行＝最新へ同期

本スクリプトは **冪等**。ベースのルール・スキル・ハーネスを更新したら、対象リポジトリで同じコマンドを
再実行するだけで最新へ同期できる（プロジェクト固有ファイルは保護されたまま）。定期的な追従にそのまま使える。

---

## アップデート確認（更新内容と手動手順の参照）

「claude-code-base のアップデートを確認して適用して」に対応する仕組み。3 つの部品で構成される:

| 部品 | 場所 | 役割 |
|------|------|------|
| **同期マーカー** `.claude/base-sync-state.json` | 対象リポジトリ（適用完了時に自動生成・更新） | 適用済みベースのコミット SHA・日時を記録する基準点。**コミットして残す** |
| **更新コミット一覧** | apply-to-repo.sh が実行冒頭に自動表示 | ベースの `git log <前回SHA>..HEAD --oneline`（前回適用以降に何が変わったか） |
| **UPDATE NOTES** [`docs/base-update-notes.md`](base-update-notes.md) | ベースリポジトリ（append-only） | **手動手順が必要な更新** だけを記録。前回適用日以降のエントリが自動抜粋される |

```bash
# 更新内容の確認のみ（適用しない）
bash apply-to-repo.sh --check-updates

# 確認 + 適用（通常の再実行。冒頭にアップデート内容が表示される）
bash apply-to-repo.sh
```

- マーカーが無い（初回適用 or 旧版で適用済み）場合は一覧をスキップして通常適用し、完了時にマーカーを作成する。
- 前回適用が古すぎてコミット一覧を辿れない場合（`--deepen 500` の範囲外）は一覧を省略し、
  `docs/base-update-notes.md` の日付ベースで手動手順のみ表示する。
- ベース側メンテナ向け: 下流に手動対応を求める変更を入れる PR では、同一 PR で
  `docs/base-update-notes.md` にエントリを追記する（記載ルールは同ファイル冒頭）。

---

## Claude に依頼する場合（自然文だけ・コマンド不要）

対象リポジトリで Claude Code セッションを開始し、**次の自然文を伝えるだけ** でよい
（ユーザーがコマンドを打つ必要も、スクリプト名を知る必要もない）:

```
claude-code-base の内容を本リポジトリに反映して
```

アップデートの取り込み（2 回目以降）も同様に自然文だけでよい:

```
claude-code-base のアップデートを確認して本リポジトリにすべて適切に適用して
```

同梱の `apply-base` スキルがこの自然文（「反映して」「適用して」「ベースを取り込んで」等）で
自動起動し、公開リポジトリ（`kai-kou/claude-code-repository-base`）前提でベースを取得して適用する。
初回（対象リポジトリにまだスキルが無い状態）でも、Claude がベース README 冒頭の「エージェントへ」の
入口を辿ってローカルなら `gh api ... | bash`、クラウドなら `git clone` / `mcp__github__get_file_contents`
経路（`gh api repos/...` はクラウドで 403・L-114）で取得するため、自然文指示だけで反映できる。
初回適用後は `apply-base` スキル自体が対象に入るため、以降の再同期も同じ自然文で起動する。

> どの環境でも自然文起動を効かせたい場合は、`.claude/skills/apply-base/` をユーザーの
> グローバル設定（`~/.claude/skills/`）に一度置いておくと、ベース未適用の新規リポジトリでも
> 自然文だけで初回適用が起動する（任意）。

---

## 前提・トラブルシュート

- **git は必須**、`gh` は任意（あれば認証・clone に利用）。`gh` 未インストールでも git で動作する。
- ベースが private の場合は `GH_TOKEN` を環境変数に設定するか `gh auth login` 済みであること。
- `--ref` にタグ / SHA を指定した場合も浅い fetch で取得する（ブランチ clone が失敗したら自動フォールバック）。
- 対象が git リポジトリでない（`.git` が無い）場合はエラーで停止する。
- 適用後はそのまま git でコミットすれば、対象リポジトリにベース設定が定着する。

---

## 参照

| ドキュメント | 関係 |
|------------|------|
| `scripts/apply-to-repo.sh` | 本スクリプト本体 |
| `scripts/bootstrap.sh` | プレースホルダ置換 + symlink 同期 + prune（apply-to-repo が内部で呼ぶ） |
| `modules.yaml` | モジュール単位の opt-out 定義（`--prune` 対象） |
| `README.md` | ベース全体の使い方 |
