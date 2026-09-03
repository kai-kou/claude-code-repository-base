#!/bin/bash
# Stop hook: 完了報告フォーマットチェック
#
# セッション終了時の最終アシスタントメッセージを検査し、
# 「PR マージ報告（プロセス）が主役で、ご依頼の再掲・アウトカムが欠落している」
# 典型バッドパターンのときだけ 1 回だけ是正リマインドを出す。
#
# 設計方針（ノイズ最小化）:
#   - no-op セッション・既に適正な報告（ご依頼/アウトカムを含む）は素通り（exit 0）
#   - 発火は「マージ」+「PR 参照」を含み、かつアウトカム系マーカーが無いときのみ
#   - stop_hook_active による再帰防止で 1 セッション 1 回に限定
#
# 【Issue #543・下流知見】判定単位が Stop イベントごと（= 直前の last_assistant_message
# だけ）であることの補正: 適正な完了報告（ご依頼/アウトカム込み）を一度出した後、
# subscribe_pr_activity 等の PR 監視で再起動したターンが「マージ済み・PR #867」のような
# トリガー語だけの短い受領応答で終わると、そのターン単体は classify_text が nudge と
# 誤判定し、既に出した適正な完了報告がまるごと再報告されてしまう（下流リポジトリで実際に
# 発生・報告済み）。本フックはターンをまたいだ状態を一切持たないのが根本原因なので、
# 「このセッションで一度適正な完了報告を出した」事実をセッションローカルのマーカーとして
# 記録し、以降の（本来は nudge 対象に見える）短い受領応答ではマーカーを見て nudge を
# 抑止する。マーカーはセッション単位でしか有効でない（他セッションのマーカーでは抑止
# しない）。git リポジトリ外・session_id 取得不可のときはマーカーを扱えないため、
# フェイルセーフとして従来どおり nudge 側に倒す（誤って抑止しない方を優先する）。
#
# SSOT: docs/rules/completion-report-rules.md / CLAUDE.md「セッション完了報告」

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/hook_block.sh
source "$HOOK_DIR/lib/hook_block.sh"
# shellcheck source=lib/hook_layer1_common.sh
source "$HOOK_DIR/lib/hook_layer1_common.sh"

# 完了報告（マージ）信号: 「マージ完了」を示す表現に限定する。
# （単独の "squash" は "squash merge 予定" 等の未完了文脈を誤検知するため含めない。
#  英語の "squash merged" は [Mm]erged が拾う・日本語の "squash でマージしました" は マージしました が拾う）
MERGE_RE='マージしました|マージした|マージ済|[Mm]erged'
PR_REF_RE='PR ?#?[0-9]+|#[0-9]{2,}|プルリク|pull/[0-9]+'
# 適正な完了報告の構造マーカー（依頼の再掲 or アウトカム）
OUTCOME_RE='ご依頼|依頼内容|ご要望|アウトカム|できるように|できるようになり|頼まれ|お願いされ|当初の指示|最初の指示'

# テキストを分類: "nudge"（是正必要）/ "ok"（素通り）
classify_text() {
  local text="$1"
  # マージ報告でなければ対象外
  if ! printf '%s' "$text" | grep -qE "$MERGE_RE"; then
    echo "ok"; return
  fi
  # PR 参照が無ければ（一般的な「マージ」言及）対象外
  if ! printf '%s' "$text" | grep -qE "$PR_REF_RE"; then
    echo "ok"; return
  fi
  # アウトカム/依頼再掲の構造があれば適正 → 素通り
  if printf '%s' "$text" | grep -qE "$OUTCOME_RE"; then
    echo "ok"; return
  fi
  echo "nudge"
}

# テキストが「適正な完了報告」そのものか判定: "yes" / "no"。
# classify_text の "ok" は 2 通り（① そもそもマージ報告ではない ② マージ報告だが構造が
# 適正）を区別しないため、マーカーを立ててよい対象（②のみ）を別関数として切り出す。
# 【誤マーク防止】Stop は final message ごとに発火するため、OUTCOME_RE（「ご依頼」等の語彙）だけを
# 根拠にすると「PR #10 はマージ済み。次はご依頼のあった機能 B に移る」のような途中の一文で
# マーカーが恒久化し、以後の不適格な最終報告が二度と nudge されない。§1 テンプレートの強い
# シグナル（見出し `✅ 完了報告` / ラベル `**ご依頼**` / `**できるようになったこと**`）を必須にする。
PROPER_TEMPLATE_RE='✅ 完了報告|\*\*ご依頼\*\*|\*\*できるようになったこと\*\*'
is_proper_report() {
  local text="$1"
  if printf '%s' "$text" | grep -qE "$MERGE_RE" \
     && printf '%s' "$text" | grep -qE "$PR_REF_RE" \
     && printf '%s' "$text" | grep -qE "$OUTCOME_RE" \
     && printf '%s' "$text" | grep -qE "$PROPER_TEMPLATE_RE"; then
    echo "yes"
  else
    echo "no"
  fi
}

# 「適正な完了報告済み」マーカーのパスを組み立てる（本体・自己テスト共用の純関数）。
report_ok_marker_path() {
  local session_id="$1" marker_dir="$2"
  printf '%s/claude-completion-report-ok-%s' "$marker_dir" "$session_id"
}

# ── セルフテスト ──
run_self_test() {
  # 本体は set -e 前提（main() 相当）だが、e2e サブプロセスは意図的に exit 2 を返すケースを
  # 検証するため、この関数内だけ errexit を無効化する（$? を素直に読み取るため）。
  # --self-test はこの関数を呼んだ直後にプロセスごと終了するので、以降の本体実行には影響しない。
  set +e
  local fail=0

  # --- classify_text（既存ケース維持）---
  assert_classify() { # $1=text $2=expected
    local got; got=$(classify_text "$1")
    if [[ "$got" != "$2" ]]; then
      echo "FAIL: classify_text expected=$2 got=$got text=[$1]"; fail=1
    fi
  }
  # バッドパターン（是正対象）
  assert_classify "PR #3052 を squash でマージしました！レビューの指摘も解消済みにゃ" "nudge"
  assert_classify "ブランチを merged しました。pull/3052 完了にゃ" "nudge"
  # 適正（素通り）
  assert_classify "**ご依頼**: 完了報告の改善。**アウトカム**: 遡らず把握できるようになったにゃ。補足: PR #3052 をマージ" "ok"
  assert_classify "PR #3052 をマージし、レビュー指摘で何ができるようになったか整理したにゃ" "ok"
  # 非マージ報告（対象外）
  assert_classify "候補を3件調べたにゃ。マージ作業は無いにゃ" "ok"
  assert_classify "ファイルを編集したにゃ" "ok"
  # 未完了文脈の squash（誤検知しないこと）
  assert_classify "PR #123 は squash merge 予定にゃ" "ok"
  # 下流知見: トリガー語だけの短い受領応答は（マーカーが無ければ）nudge のまま
  assert_classify "PR #867 マージ済みを確認したにゃ" "nudge"

  # --- is_proper_report ---
  assert_proper() { # $1=text $2=expected
    local got; got=$(is_proper_report "$1")
    if [[ "$got" != "$2" ]]; then
      echo "FAIL: is_proper_report expected=$2 got=$got text=[$1]"; fail=1
    fi
  }
  assert_proper "**ご依頼**: 完了報告の改善。**アウトカム**: 遡らず把握できるようになったにゃ。PR #3052 をマージしました" "yes"
  assert_proper "PR #867 マージ済みを確認したにゃ" "no"
  assert_proper "ファイルを編集したにゃ" "no"
  assert_proper "PR #3052 を squash でマージしました！レビューの指摘も解消済みにゃ" "no"
  # 途中経過の一文が OUTCOME_RE の語彙を偶然含んでもテンプレートの強いシグナルが無ければマークしない
  assert_proper "PR #10 はマージ済みです。次はご依頼のあった機能 B に移りますにゃ" "no"
  assert_proper "## ✅ 完了報告
**ご依頼**: 〇〇の実装。
**できるようになったこと**: △△ができるようになったにゃ。
[PR #11](https://example.com/pull/11) をマージしました" "yes"

  # --- report_ok_marker_path（往復テスト）---
  local tmp_dir marker
  tmp_dir=$(mktemp -d 2>/dev/null || echo "")
  if [[ -n "$tmp_dir" ]]; then
    marker=$(report_ok_marker_path "sessX" "$tmp_dir")
    if [[ "$marker" != "${tmp_dir}/claude-completion-report-ok-sessX" ]]; then
      echo "FAIL: report_ok_marker_path のパス組み立てが期待と異なる: $marker"; fail=1
    fi
    [[ ! -f "$marker" ]] || { echo "FAIL: マーカー未作成時点で存在してしまっている"; fail=1; }
    : > "$marker"
    [[ -f "$marker" ]] || { echo "FAIL: マーカー touch 後にファイルが見つからない"; fail=1; }
    rm -rf "$tmp_dir"
  fi

  # --- 本体 e2e（実プロセス起動・CLAUDE_HOOK_REPORT_MARKER_DIR で保存先を一時ディレクトリへ差し替え）---
  local e2e_dir
  e2e_dir=$(mktemp -d 2>/dev/null || echo "")
  if [[ -n "$e2e_dir" ]]; then
    local proper_text short_receipt_text out exit_code marker_path

    proper_text='**ご依頼**: 完了報告の改善。**アウトカム**: 遡らず把握できるようになったにゃ。PR #867 をマージしました'
    short_receipt_text='PR #867 マージ済みを確認したにゃ'

    # ① 適正な完了報告を1回出す → exit 0 かつマーカーが作成される
    out=$(CLAUDE_HOOK_REPORT_MARKER_DIR="$e2e_dir" bash "${BASH_SOURCE[0]}" \
      <<< "$(jq -n --arg m "$proper_text" '{session_id:"sess-e2e-ok",stop_hook_active:false,last_assistant_message:$m}')" 2>&1 >/dev/null)
    exit_code=$?
    marker_path=$(report_ok_marker_path "sess-e2e-ok" "$e2e_dir")
    if [[ "$exit_code" -eq 0 ]]; then :; else echo "FAIL: e2e①: 適正報告なのに exit ${exit_code}（出力: ${out}）"; fail=1; fi
    if [[ -f "$marker_path" ]]; then :; else echo "FAIL: e2e①: 適正報告後にマーカーが作られなかった"; fail=1; fi

    # ② 同一セッションでトリガー語だけの短い受領応答 → マーカーがあるので exit 0（nudge しない）
    out=$(CLAUDE_HOOK_REPORT_MARKER_DIR="$e2e_dir" bash "${BASH_SOURCE[0]}" \
      <<< "$(jq -n --arg m "$short_receipt_text" '{session_id:"sess-e2e-ok",stop_hook_active:false,last_assistant_message:$m}')" 2>&1 >/dev/null)
    exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then :; else echo "FAIL: e2e②: マーカーありなのに短い受領応答が exit ${exit_code}（出力: ${out}）"; fail=1; fi

    # ③ マーカーが無いセッションで同じ短い受領応答 → 従来どおり exit 2 + [report-format]
    out=$(CLAUDE_HOOK_REPORT_MARKER_DIR="$e2e_dir" bash "${BASH_SOURCE[0]}" \
      <<< "$(jq -n --arg m "$short_receipt_text" '{session_id:"sess-e2e-no-marker",stop_hook_active:false,last_assistant_message:$m}')" 2>&1 >/dev/null)
    exit_code=$?
    if [[ "$exit_code" -eq 2 ]]; then :; else echo "FAIL: e2e③: マーカー無しなのに exit ${exit_code}（出力: ${out}）"; fail=1; fi
    if printf '%s' "$out" | grep -q '\[report-format\]'; then :; else echo "FAIL: e2e③: stderr に [report-format] タグが無い（出力: ${out}）"; fail=1; fi

    rm -rf "$e2e_dir"
  else
    echo "  (e2e スキップ: 一時ディレクトリを作成できない環境)"
  fi

  if [[ $fail -eq 0 ]]; then echo "stop-completion-report-check: self-test PASS"; fi
  return $fail
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

input=$(cat 2>/dev/null || true)

# 再帰防止: 既にこのフック起因で再開済みなら何もしない
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // "false"' 2>/dev/null || echo "false")
if [[ "$stop_hook_active" == "true" ]]; then exit 0; fi

# 最終アシスタントメッセージは公式スキーマの last_assistant_message を優先する
# （hook-events-reference.md #4: transcript は非同期書き込みで現在ターンの最新メッセージを
# 含まないことがあると公式に明記されている。last_assistant_message は Stop 時点で
# 確実に「このターンの最終テキスト」を持つ）。空のときだけ transcript 抽出へフォールバックする
# （last_assistant_message 自体が未提供のハーネスバージョン・異常系への保険）。
last_text=$(printf '%s' "$input" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")

if [[ -z "$last_text" ]]; then
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || echo "")
  if [[ -n "$transcript" ]] && [[ -r "$transcript" ]]; then
    last_text=$(tail -n 400 "$transcript" 2>/dev/null | jq -rs '
      [ .[]
        | select(.type=="assistant")
        | ((.message.content // []) | map(select(.type=="text") | .text) | join("\n"))
        | select(length > 0)
      ] | last // ""
    ' 2>/dev/null || echo "")
  fi
fi

if [[ -z "$last_text" ]]; then exit 0; fi

# session_id / マーカー保存先を解決する。どちらも解決できない場合はマーカーを一切扱わず
# （= 従来どおり classify_text の結果だけで判断する）フェイルセーフは nudge 側に倒す。
session_id=$(hook_extract_session_id "$input" || echo "")
report_marker_dir="${CLAUDE_HOOK_REPORT_MARKER_DIR:-$(git rev-parse --git-dir 2>/dev/null || echo "")}"

# 適正な完了報告を観測したら、以降の短い受領応答で誤って再報告させないようマーカーを立てる。
if [[ "$(is_proper_report "$last_text")" == "yes" ]] && [[ -n "$session_id" ]] && [[ -n "$report_marker_dir" ]]; then
  mkdir -p "$report_marker_dir" 2>/dev/null || true
  : > "$(report_ok_marker_path "$session_id" "$report_marker_dir")" 2>/dev/null || true
fi

if [[ "$(classify_text "$last_text")" == "nudge" ]]; then
  # このセッションで既に適正な完了報告を出したマーカーがあれば、今回が
  # トリガー語だけの短い受領応答であっても再報告を求めず素通りする（#543）。
  if [[ -n "$session_id" ]] && [[ -n "$report_marker_dir" ]]; then
    if [[ -f "$(report_ok_marker_path "$session_id" "$report_marker_dir")" ]]; then
      exit 0
    fi
  fi
  hook_block "[report-format] 📋 完了報告フォーマット確認: 直前の報告が「PR マージの詳細」中心になっているにゃ。逐語で再送するのではなく、docs/rules/completion-report-rules.md §1 のテンプレートに沿って **簡潔に書き直して** にゃ（プロセス文言・マージ手順・レビュー往復は削り、先頭に「ご依頼（最初に頼まれたことの再掲）→ アウトカム（何ができるようになったか）」を置く。PR 番号は末尾の補足 1 行）。"
fi

exit 0
