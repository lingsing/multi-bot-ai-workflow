#!/usr/bin/env bash
#
# news_relay.sh —— 研究类接力示例：抓取（codex --search exec）→ 分析（claude -p）→ 市场核对（只读）
#
# 边界：只分析不下单。任何一步都不登录交易账户、不生成可执行的交易指令。
# 每步输出都会被扫描并列出 [未核实] 项；缺少来源链接的新闻条目自动视为未核实。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
用法:
  news_relay.sh [--mode brief|alert] [--topic "关注主题"] [--dry-run|--run]

模式:
  brief   工作日早报：汇总当日要闻
  alert   重大事件提醒（工作日 10/14/18/22 点）：只关注最近数小时内的重大事件，没有就输出「无重大事件」

接力步骤:
  1. 抓取      codex --search exec   网页抓取，每条附来源链接
  2. 分析      claude -p             基于第 1 步输出做影响分析，不引入新事实
  3. 市场核对  codex --search exec   只读核对第 2 步提到的公开市场信息，不下单、不给买卖指令

选项:
  -m, --mode MODE      brief（默认）或 alert
      --topic TEXT     关注主题（默认：科技与宏观经济）
      --out-dir DIR    输出目录（默认 examples/output/news-<时间>/）
      --dry-run        只打印计划，写入占位输出（默认）
      --run            真正调用 CLI
  -h, --help           显示本帮助

输出: 01-fetch.md  02-analysis.md  03-market-check.md  relay-summary.md
EOF
}

MODE="brief" TOPIC="科技与宏观经济" OUT_DIR=""
while (($#)); do
  case "$1" in
    -m | --mode) need_arg "$1" "${2-}" "$#"; MODE="$2"; shift 2 ;;
    --topic) need_arg "$1" "${2-}" "$#"; TOPIC="$2"; shift 2 ;;
    --out-dir) need_arg "$1" "${2-}" "$#"; OUT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --run)
      # shellcheck disable=SC2034  # DRY_RUN 定义在 lib/common.sh，由其中的 is_dry_run 读取
      DRY_RUN=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log_error "未知参数: $1"; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in brief | alert) ;; *) die "--mode 只能是 brief 或 alert" 2 ;; esac

check_stop
check_cli codex || exit 1
check_cli claude || exit 1

RUN_TS="$(ts_compact)"
[[ -n "$OUT_DIR" ]] || OUT_DIR="$WF_OUTPUT_DIR/news-$RUN_TS"
mkdir -p "$OUT_DIR"
F1="$OUT_DIR/01-fetch.md"
F2="$OUT_DIR/02-analysis.md"
F3="$OUT_DIR/03-market-check.md"
SUMMARY="$OUT_DIR/relay-summary.md"

MARK_RULE="凡是无法给出可访问来源链接、或来源之间相互矛盾的内容，必须在该行末尾标注 [未核实]。"
NO_TRADE_RULE="本流程只分析不下单：不登录任何交易账户，不给出买入、卖出、仓位等操作指令。"

# ---------- 提示词 ----------
if [[ "$MODE" == "brief" ]]; then
  P1="抓取今日与「$TOPIC」相关的要闻，用 markdown 列表输出，每条一行：标题 — 一句话摘要 — 来源链接。$MARK_RULE"
else
  P1="检索最近数小时内与「$TOPIC」相关的重大事件，用 markdown 列表输出，每条一行：标题 — 一句话摘要 — 来源链接；若没有重大事件，只输出「无重大事件」。$MARK_RULE"
fi
P2_HEAD="以下是新闻抓取结果。请分析每条可能的影响，只基于给出的材料，不引入材料之外的新事实；对标注 [未核实] 的条目，分析结论也必须标注 [未核实]。$NO_TRADE_RULE"
P3_HEAD="以下是新闻影响分析。请只读核对其中提到的公开市场信息（如指数、价格、公告是否属实），逐条给出：核对结果（一致/不一致/无法核对）+ 来源链接；无法核对的标注 [未核实]。$NO_TRADE_RULE"

# ---------- 工具函数 ----------
# 列出未核实项：显式标注 [未核实] 的行 + （仅抓取步骤）缺少链接的列表行
list_unverified() {
  local file="$1" step="$2"
  {
    grep -n '未核实' "$file" || true
    if [[ "$step" == "1" ]]; then
      awk '/^[[:space:]]*[-*] / && $0 !~ /https?:\/\// && $0 !~ /未核实/ {print NR ":" $0 "  ← 缺少来源链接，视为 [未核实]"}' "$file"
    fi
  }
}

# 扫描输出中是否出现交易指令类词汇（只告警标注，本流程本来就不会执行任何交易）
scan_trade_words() {
  local file="$1" rc=0
  gate_check "$(cat "$file")" || rc=$?
  if [[ "$rc" -eq 20 ]]; then
    log_warn "$(basename "$file") 中出现交易指令类词汇「$WF_GATE_HIT」：仅作为分析文本保留，不执行，不作为建议转发"
    echo "「$WF_GATE_HIT」"
  fi
}

STEP_REPORT=""
run_step() {
  local n="$1" name="$2" outfile="$3"
  shift 3
  check_stop   # 每一步开始前检查「停」
  log_info "步骤 $n：$name"
  if is_dry_run; then
    run_cmd "$@"
    {
      echo "<!-- DRY-RUN 占位输出：未调用任何 CLI -->"
      echo "- [DRY-RUN] 步骤 $n（$name）的示例输出条目 — https://example.com/placeholder"
      echo "- [DRY-RUN] 一条缺少来源链接的示例条目"
      echo "- [DRY-RUN] 一条来源相互矛盾的示例条目 [未核实]"
    } >"$outfile"
  else
    "$@" >"$outfile"
  fi

  local unverified trade
  unverified="$(list_unverified "$outfile" "$n")"
  trade="$(scan_trade_words "$outfile")"
  echo "---- 步骤 $n 未核实项 ----"
  if [[ -n "$unverified" ]]; then echo "$unverified"; else echo "（无）"; fi

  STEP_REPORT+=$'\n'"## 步骤 $n：$name"$'\n\n'"- 输出：\`$(basename "$outfile")\`"$'\n'
  if [[ -n "$trade" ]]; then
    STEP_REPORT+="- 注意：出现交易指令类词汇 $trade，已忽略，不执行。"$'\n'
  fi
  STEP_REPORT+="- 未核实项："$'\n\n''```text'$'\n'"${unverified:-（无）}"$'\n''```'$'\n'
}

# ---------- 接力 ----------
log_info "新闻接力（$MODE）开始：$(is_dry_run && echo dry-run || echo run)；输出目录 $(wf_relpath "$OUT_DIR")"

run_step 1 "抓取（codex --search exec）" "$F1" \
  codex --search exec "$P1"

run_step 2 "分析（claude -p）" "$F2" \
  claude -p "$P2_HEAD"$'\n\n'"$(cat "$F1")"

run_step 3 "市场核对（只读，codex --search exec）" "$F3" \
  codex --search exec "$P3_HEAD"$'\n\n'"$(cat "$F2")"

{
  printf '# 新闻接力汇总（%s）%s\n\n' "$MODE" "$RUN_TS"
  printf -- '- 模式：%s\n' "$(is_dry_run && echo 'dry-run（占位输出，未调用 CLI）' || echo run)"
  printf -- '- 主题：%s\n' "$TOPIC"
  printf -- '- 边界：只分析不下单；[未核实] 项不作为事实引用，转述时必须保留标注。\n'
  printf '%s\n' "$STEP_REPORT"
  printf '\n---\n本汇总由调度助手转给本人；任何据此采取的交易行为都需要本人另行决定并手动操作。\n'
} >"$SUMMARY"

log_info "接力完成，汇总：$(wf_relpath "$SUMMARY")"
cat "$SUMMARY"
