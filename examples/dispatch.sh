#!/usr/bin/env bash
#
# dispatch.sh —— “调度助手”的最小示例：按任务类型路由到执行者 CLI，执行后汇总为 markdown 摘要。
#
# 默认 dry-run（只打印计划），需显式 --run 才会真正调用 codex / claude / codebuddy。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
用法:
  dispatch.sh --type TYPE --task "任务描述" [选项]
  dispatch.sh --batch FILE [选项]

任务类型 (TYPE) 与默认执行者:
  image      生图            → codex      (codex exec)
  research   中大型调研      → codex      (codex --search exec)
  code       编程            → claude     (claude -p)        回退: codex
  video      视频剪辑        → claude     (claude -p，可配合 ffmpeg)
  copy       文案            → codebuddy  (codebuddy -p)     回退: claude
  translate  翻译            → codebuddy  (codebuddy -p)     回退: claude
  weekly     周报提炼        → codebuddy  (codebuddy -p)     回退: claude
  screen     资料初筛        → codebuddy  (codebuddy -p)     回退: claude

选项:
  -t, --type TYPE          任务类型（见上）
  -k, --task TEXT          任务描述
  -b, --batch FILE         批量任务文件，每行 "类型|任务描述"，# 开头为注释
  -e, --executor NAME      人工指定执行者（codex|claude|codebuddy），覆盖默认路由
  -o, --summary FILE       摘要输出路径（默认 examples/output/summary-<时间>.md）
      --confirm            对“需确认”类任务在终端里逐条询问本人（仅 --run 且交互终端有效）
      --design-approved    声明前端设计已获批（否则前端开发类任务会被拦截）
      --dry-run            只打印计划，不调用 CLI（默认）
      --run                真正调用 CLI
  -h, --help               显示本帮助

门禁（在路由之前检查）:
  - 含 下单/买入/卖出/开仓/平仓 等交易下单词 → 直接拒绝，无任何参数可绕过
  - 含 发布/推送/发送/上线 等对外动作词       → 拒绝自动执行，需本人确认（--run --confirm）
  - code 类且涉及 前端/页面/界面              → 未加 --design-approved 时拦截
  - 含 选型/技术栈/最终方案                   → 放行，但要求执行者只给对比方案，由人拍板
  - 存在 STOP 标志                            → 立即退出（见 stop_all.sh）

退出码: 0=完成或计划已生成（被门禁拦截不算错误）  2=参数错误  3=STOP  4=--run 下有任务执行失败

示例:
  ./dispatch.sh --type research --task "调研本地向量数据库的几种常见方案，列出优缺点"
  ./dispatch.sh --batch tasks.example.txt
  ./dispatch.sh --type copy --task "写一段产品更新文案并发布" --run --confirm
EOF
}

# ---------- 路由表 ----------
VALID_TYPES="image research code video copy translate weekly screen"

route_primary() {
  case "$1" in
    image | research) echo codex ;;
    code | video) echo claude ;;
    copy | translate | weekly | screen) echo codebuddy ;;
    *) return 1 ;;
  esac
}

# 回退只在“主执行者 CLI 不可用”时发生；执行过但失败的任务不自动回退（可能已改了部分文件）
route_fallback() {
  case "$1" in
    research) echo claude ;;   # 降级：结论全部按 [未核实] 处理
    code) echo codex ;;
    copy | translate | weekly | screen) echo claude ;;
    *) echo none ;;            # image / video 无回退，退回调度助手报告给人
  esac
}

type_label() {
  case "$1" in
    image) echo "生图" ;; research) echo "中大型调研" ;; code) echo "编程" ;;
    video) echo "视频剪辑" ;; copy) echo "文案" ;; translate) echo "翻译" ;;
    weekly) echo "周报提炼" ;; screen) echo "资料初筛" ;; *) echo "未知" ;;
  esac
}

type_hint() {
  case "$1" in
    image) echo "生成图片，保存为当前目录下的新文件，不覆盖已有文件。" ;;
    research) echo "中大型调研：给出结论、依据与来源链接；无法核实的内容标注[未核实]。" ;;
    code) echo "编程任务：修改前先备份或在新分支进行；只改与任务相关的文件；给出验收方式。" ;;
    video) echo "视频剪辑：可调用本机 ffmpeg；不覆盖原素材，输出到新文件；列出所用命令。" ;;
    copy) echo "撰写文案，只输出草稿，不要发布。" ;;
    translate) echo "翻译，保留原文格式；术语不确定处标注。" ;;
    weekly) echo "从给定材料中提炼周报要点，不补充材料中没有的事实。" ;;
    screen) echo "资料初筛：逐条标注相关/不相关及理由，不下最终结论。" ;;
  esac
}

is_valid_type() {
  local t
  for t in $VALID_TYPES; do
    [[ "$t" == "$1" ]] && return 0
  done
  return 1
}

# 根据执行者与类型构造命令，结果放在全局数组 CMD
CMD=()
build_cmd() {
  local executor="$1" type="$2" prompt="$3"
  case "$executor" in
    codex)
      if [[ "$type" == "research" ]]; then
        CMD=(codex --search exec "$prompt")
      else
        CMD=(codex exec "$prompt")
      fi
      ;;
    claude) CMD=(claude -p "$prompt") ;;
    codebuddy) CMD=(codebuddy -p "$prompt") ;;
    *) return 1 ;;
  esac
}

# ---------- 参数解析 ----------
TYPE="" TASK="" BATCH="" EXECUTOR_OVERRIDE="" SUMMARY_FILE=""
CONFIRM=0 DESIGN_APPROVED=0

while (($#)); do
  case "$1" in
    -t | --type) need_arg "$1" "${2-}" "$#"; TYPE="$2"; shift 2 ;;
    -k | --task) need_arg "$1" "${2-}" "$#"; TASK="$2"; shift 2 ;;
    -b | --batch) need_arg "$1" "${2-}" "$#"; BATCH="$2"; shift 2 ;;
    -e | --executor) need_arg "$1" "${2-}" "$#"; EXECUTOR_OVERRIDE="$2"; shift 2 ;;
    -o | --summary) need_arg "$1" "${2-}" "$#"; SUMMARY_FILE="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    --design-approved) DESIGN_APPROVED=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --run) DRY_RUN=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log_error "未知参数: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$EXECUTOR_OVERRIDE" ]]; then
  case "$EXECUTOR_OVERRIDE" in
    codex | claude | codebuddy) ;;
    *) die "--executor 只能是 codex|claude|codebuddy" 2 ;;
  esac
fi

if [[ -z "$BATCH" && (-z "$TYPE" || -z "$TASK") ]]; then
  log_error "需要 --type 与 --task，或 --batch"
  usage >&2
  exit 2
fi

check_stop

mkdir -p "$WF_OUTPUT_DIR"
RUN_TS="$(ts_compact)"
[[ -n "$SUMMARY_FILE" ]] || SUMMARY_FILE="$WF_OUTPUT_DIR/summary-$RUN_TS.md"
ROWS_FILE="$(mktemp)"
DETAILS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE" "$DETAILS_FILE"' EXIT

N_TOTAL=0 N_DONE=0 N_PLANNED=0 N_BLOCKED=0 N_FAILED=0

# record 序号 类型 执行者 状态 任务 命令文本 输出文件(可空) 备注
record() {
  local idx="$1" type="$2" executor="$3" status="$4" task="$5" cmdtxt="$6" outfile="$7" note="$8"
  local outcell="-"
  [[ -n "$outfile" ]] && outcell="\`$(wf_relpath "$outfile")\`"
  printf '| %s | %s | %s | %s | %s |\n' "$idx" "$(type_label "$type")" "$executor" "$status" "$outcell" >>"$ROWS_FILE"
  {
    printf '\n### #%s %s（%s）\n\n' "$idx" "$(type_label "$type")" "$status"
    printf -- '- 任务：%s\n' "$task"
    printf -- '- 执行者：%s\n' "$executor"
    [[ -n "$note" ]] && printf -- '- 备注：%s\n' "$note"
    if [[ -n "$cmdtxt" ]]; then
      # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 代码块标记
      printf -- '- 命令：\n\n```bash\n%s\n```\n' "$cmdtxt"
    fi
    if [[ -n "$outfile" && -s "$outfile" ]]; then
      printf '\n输出节选（前 20 行）：\n\n```text\n'
      head -n 20 "$outfile"
      printf '\n```\n'
      if grep -q '未核实' "$outfile"; then
        printf '\n> 输出中包含 [未核实] 项，汇总时不作为事实引用。\n'
      fi
    fi
  } >>"$DETAILS_FILE"
}

process_task() {
  local idx="$1" type="$2" task="$3"
  local rc=0 executor fallback prompt note="" cmdtxt outfile=""

  N_TOTAL=$((N_TOTAL + 1))
  check_stop   # 每条任务前都检查，「停」可以在批量任务中途生效

  if ! is_valid_type "$type"; then
    log_warn "#$idx 未知任务类型 '$type'，不猜测路由，退回给人"
    N_BLOCKED=$((N_BLOCKED + 1))
    record "$idx" "$type" "-" "已拦截：未知类型" "$task" "" "" "可选类型：$VALID_TYPES"
    return 0
  fi

  # 门禁 1/2：交易下单 → 拒绝；对外动作 → 需本人确认
  gate_check "$task" || rc=$?
  if [[ "$rc" -eq 20 ]]; then
    log_warn "#$idx 命中交易下单关键词「$WF_GATE_HIT」，直接拒绝（只分析不下单）"
    N_BLOCKED=$((N_BLOCKED + 1))
    record "$idx" "$type" "-" "已拒绝：交易下单类" "$task" "" "" "命中「$WF_GATE_HIT」。交易类禁止自动下单，无参数可绕过。"
    return 0
  fi
  if [[ "$rc" -eq 10 ]]; then
    local ok=0
    if ! is_dry_run && [[ "$CONFIRM" -eq 1 ]]; then
      if confirm_by_human "#$idx 任务含对外动作「$WF_GATE_HIT」：$task"; then ok=1; fi
    fi
    if [[ "$ok" -ne 1 ]]; then
      log_warn "#$idx 命中对外动作关键词「$WF_GATE_HIT」，未经本人确认，不自动执行"
      N_BLOCKED=$((N_BLOCKED + 1))
      record "$idx" "$type" "-" "待本人确认" "$task" "" "" "命中「$WF_GATE_HIT」。可先让执行者只出草稿；确认后用 --run --confirm 在终端执行。"
      return 0
    fi
    note="本人已在终端确认对外动作「$WF_GATE_HIT」。"
  fi

  # 门禁 3：前端开发需设计获批
  if [[ "$type" == "code" ]] && is_frontend_task "$task" && [[ "$DESIGN_APPROVED" -ne 1 ]]; then
    log_warn "#$idx 前端开发任务，设计未获批，不开发"
    N_BLOCKED=$((N_BLOCKED + 1))
    record "$idx" "$type" "-" "已拦截：设计未获批" "$task" "" "" "命中「$WF_GATE_HIT」。设计获批后加 --design-approved。"
    return 0
  fi

  prompt="$task"$'\n'"$(type_hint "$type")"
  # 门禁 4：关键选型由人决定
  if is_decision_task "$task"; then
    prompt+=$'\n'"本任务涉及关键选型：只输出候选方案、对比维度与风险，不做最终决定，最终选型由人拍板。"
    note+="涉及关键选型（「$WF_GATE_HIT」），执行者只出对比方案。"
  fi
  prompt+=$'\n'"$WF_GUARD_SUFFIX"

  # 路由
  if [[ -n "$EXECUTOR_OVERRIDE" ]]; then
    executor="$EXECUTOR_OVERRIDE"
    note+="执行者由人工指定。"
  else
    executor="$(route_primary "$type")"
  fi
  fallback="$(route_fallback "$type")"

  if ! have_cmd "$executor"; then
    if is_dry_run; then
      log_warn "#$idx 未找到 '$executor'（dry-run 仅展示计划；--run 时将尝试回退：$fallback）"
    elif [[ -z "$EXECUTOR_OVERRIDE" && "$fallback" != "none" ]] && have_cmd "$fallback"; then
      log_warn "#$idx 主执行者 '$executor' 不可用，回退到 '$fallback'"
      note+="主执行者 $executor 不可用，已回退到 $fallback。"
      [[ "$type" == "research" ]] && note+="回退执行者无联网检索，结论全部视为 [未核实]。"
      executor="$fallback"
    else
      log_error "#$idx 执行者 '$executor' 不可用且无可用回退，退回给人处理"
      N_FAILED=$((N_FAILED + 1))
      record "$idx" "$type" "$executor" "失败：执行者不可用" "$task" "" "" "回退：$fallback"
      return 0
    fi
  fi

  build_cmd "$executor" "$type" "$prompt"
  cmdtxt="$(fmt_cmd "${CMD[@]}")"
  [[ "$type" == "video" ]] && note+="视频类由 Claude Code 调用本机 ffmpeg 完成。"

  if is_dry_run; then
    run_cmd "${CMD[@]}"
    N_PLANNED=$((N_PLANNED + 1))
    record "$idx" "$type" "$executor" "计划（dry-run）" "$task" "$cmdtxt" "" "$note"
    return 0
  fi

  outfile="$WF_OUTPUT_DIR/task-$RUN_TS-$idx-$type.md"
  log_info "#$idx [$type] → $executor"
  if "${CMD[@]}" >"$outfile" 2>&1; then
    N_DONE=$((N_DONE + 1))
    record "$idx" "$type" "$executor" "完成" "$task" "$cmdtxt" "$outfile" "$note"
  else
    rc=$?
    N_FAILED=$((N_FAILED + 1))
    record "$idx" "$type" "$executor" "失败（退出码 $rc）" "$task" "$cmdtxt" "$outfile" "${note}执行失败不自动回退，避免在已部分修改的基础上叠加改动。"
  fi
}

# ---------- 执行 ----------
log_info "模式：$(is_dry_run && echo 'dry-run（只打印计划）' || echo 'run（真正调用 CLI）')"

if [[ -n "$BATCH" ]]; then
  [[ -f "$BATCH" ]] || die "批量任务文件不存在: $BATCH" 2
  i=0
  # 批量文件走 fd 3，保留 stdin 给 --confirm 的终端确认
  while IFS='|' read -r b_type b_task <&3 || [[ -n "${b_type:-}" ]]; do
    b_type="$(trim "${b_type:-}")"
    b_task="$(trim "${b_task:-}")"
    [[ -z "$b_type" || "$b_type" == \#* ]] && continue
    i=$((i + 1))
    process_task "$i" "$b_type" "$b_task"
  done 3<"$BATCH"
else
  process_task 1 "$TYPE" "$TASK"
fi

{
  printf '# 调度汇总 %s\n\n' "$RUN_TS"
  printf -- '- 模式：%s\n' "$(is_dry_run && echo 'dry-run（未调用任何 CLI）' || echo 'run')"
  printf -- '- 任务数：%s；完成：%s；计划：%s；拦截/待确认：%s；失败：%s\n\n' \
    "$N_TOTAL" "$N_DONE" "$N_PLANNED" "$N_BLOCKED" "$N_FAILED"
  printf '| # | 类型 | 执行者 | 状态 | 输出 |\n|---|---|---|---|---|\n'
  cat "$ROWS_FILE"
  printf '\n## 明细\n'
  cat "$DETAILS_FILE"
  printf '\n---\n汇总规则：执行者输出中的 [未核实] 项不作为事实；对外动作与交易类任务不会被自动执行。\n'
} >"$SUMMARY_FILE"

log_info "摘要已写入：$(wf_relpath "$SUMMARY_FILE")"
cat "$SUMMARY_FILE"

if [[ "$N_FAILED" -gt 0 && "$DRY_RUN" -eq 0 ]]; then
  exit 4
fi
