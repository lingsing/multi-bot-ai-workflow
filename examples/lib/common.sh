#!/usr/bin/env bash
# shellcheck shell=bash
#
# examples/lib/common.sh —— 示例脚本共享库
#   - 日志：log_info / log_warn / log_error / die
#   - dry-run：DRY_RUN 默认 1，脚本需显式 --run 才真正调用外部 CLI
#   - 「停」开关：check_stop 检查 STOP 标志文件
#   - 门禁关键词：gate_check 判断任务描述是否需人工确认 / 直接拒绝
#
# 用法（在 examples/ 下的脚本中）：
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
#
# 兼容性：刻意兼容 macOS 自带的 bash 3.2（不用 ${var,,}、关联数组、mapfile）。
# 本文件只定义变量和函数，不应直接执行。

if [[ -n "${_WF_COMMON_LOADED:-}" ]]; then
  return 0
fi
_WF_COMMON_LOADED=1

# ---------- 目录约定（全部相对仓库计算，不写死任何绝对路径） ----------
WF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF_EXAMPLES_DIR="$(cd "$WF_LIB_DIR/.." && pwd)"
WF_REPO_DIR="$(cd "$WF_EXAMPLES_DIR/.." && pwd)"
WF_STATE_DIR="${WF_STATE_DIR:-$WF_EXAMPLES_DIR/.state}"     # STOP 标志、监控快照
WF_OUTPUT_DIR="${WF_OUTPUT_DIR:-$WF_EXAMPLES_DIR/output}"   # 摘要、报告
WF_STOP_FLAG="$WF_STATE_DIR/STOP"

# 默认 dry-run：只打印计划，不调用任何外部 CLI
DRY_RUN=1

# ---------- 门禁关键词 ----------
# 命中“需确认”类：对外发消息 / 发布 / 推送，必须本人确认后才能执行
WF_CONFIRM_KEYWORDS=(发布 推送 发送 群发 外发 公开发表 上线 发帖 publish push send deploy)
# 命中“禁止”类：交易下单，永远不自动执行（没有任何参数可以绕过）
WF_DENY_KEYWORDS=(下单 买入 卖出 开仓 平仓 加仓 减仓 挂单 "place order" "market order" "limit order")
# 前端开发：设计未获批不开发
WF_FRONTEND_KEYWORDS=(前端 页面 界面 frontend "web ui")
# 关键选型：只出对比方案，由人拍板
WF_DECISION_KEYWORDS=(选型 拍板 技术栈 最终方案)

# 附加到每一个委托给执行者的提示词末尾的“守则”
# shellcheck disable=SC2034  # 供 dispatch.sh 等调用方读取
WF_GUARD_SUFFIX="【执行守则】修改任何文件前先备份；只改与本任务相关的文件，不改无关配置；不对外发送、发布或推送任何内容；不进行任何交易操作；无法核实的信息标注[未核实]，不要当作事实；结束时列出：已改文件、验收方式、未核实项。"

# ---------- 日志 ----------
_wf_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '[%s] [INFO]  %s\n' "$(_wf_ts)" "$*" >&2; }
log_warn()  { printf '[%s] [WARN]  %s\n' "$(_wf_ts)" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$(_wf_ts)" "$*" >&2; }

# die "消息" [退出码]
die() {
  local code="${2:-1}"
  log_error "$1"
  exit "$code"
}

# ---------- 小工具 ----------
is_dry_run() { [[ "$DRY_RUN" -eq 1 ]]; }
have_cmd()   { command -v "$1" >/dev/null 2>&1; }
ts_compact() { date '+%Y%m%d-%H%M%S'; }
to_lower()   { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
trim()       { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# 把路径显示为相对仓库根目录的形式，避免在日志/报告里出现本机绝对路径
wf_relpath() {
  local p="$1"
  if [[ "$p" == "$WF_REPO_DIR" ]]; then
    printf '.'
  elif [[ "$p" == "$WF_REPO_DIR"/* ]]; then
    printf '%s' "${p#"$WF_REPO_DIR"/}"
  else
    printf '%s' "$p"
  fi
}

# 检查选项是否带了参数值：need_arg "$1" "${2-}" "$#"
need_arg() {
  if [[ "$3" -lt 2 || -z "$2" ]]; then
    die "选项 $1 需要一个参数值（--help 查看用法）" 2
  fi
}

# 打印命令（用于 dry-run 展示），对含空格/非 ASCII 的参数加单引号
fmt_cmd() {
  local out="" a safe='^[A-Za-z0-9_./=:,@+%-]+$'
  for a in "$@"; do
    if [[ "$a" =~ $safe ]]; then
      out+="$a "
    else
      a="${a//\'/\'\\\'\'}"
      out+="'$a' "
    fi
  done
  printf '%s' "${out% }"
}

# dry-run 时只打印，--run 时才执行
run_cmd() {
  if is_dry_run; then
    printf '[DRY-RUN] 将执行: %s\n' "$(fmt_cmd "$@")"
    return 0
  fi
  log_info "执行: $1 ..."
  "$@"
}

# 提示 CLI 是否可用；dry-run 下缺失只警告，--run 下缺失返回非 0
check_cli() {
  local cli="$1"
  if have_cmd "$cli"; then
    return 0
  fi
  if is_dry_run; then
    log_warn "未找到 '$cli' 命令（dry-run 仅展示计划，不影响）"
    return 0
  fi
  log_error "未找到 '$cli' 命令，无法以 --run 执行"
  return 1
}

# ---------- 「停」开关 ----------
check_stop() {
  if [[ -f "$WF_STOP_FLAG" ]]; then
    log_warn "检测到 STOP 标志（$(wf_relpath "$WF_STOP_FLAG")），按「停」规则立即退出，不执行任何操作。"
    log_warn "确认可以恢复后执行：./stop_all.sh --clear --run"
    exit 3
  fi
}

# ---------- 门禁 ----------
# 用法：gate_check "任务描述"; rc=$?
# 返回：0=放行  10=需本人确认（对外发布/推送/发送）  20=禁止（交易下单）
# 命中的关键词写入 WF_GATE_HIT
WF_GATE_HIT=""
_wf_contains_any() {
  # _wf_contains_any "小写文本" 关键词...
  local text="$1" kw
  shift
  for kw in "$@"; do
    if [[ "$text" == *"$(to_lower "$kw")"* ]]; then
      WF_GATE_HIT="$kw"
      return 0
    fi
  done
  return 1
}

gate_check() {
  local text
  text="$(to_lower "$1")"
  # shellcheck disable=SC2034  # 调用方读取 WF_GATE_HIT 获知命中的关键词
  WF_GATE_HIT=""
  if _wf_contains_any "$text" "${WF_DENY_KEYWORDS[@]}"; then
    return 20
  fi
  if _wf_contains_any "$text" "${WF_CONFIRM_KEYWORDS[@]}"; then
    return 10
  fi
  return 0
}

# 是否命中前端关键词
is_frontend_task() { _wf_contains_any "$(to_lower "$1")" "${WF_FRONTEND_KEYWORDS[@]}"; }
# 是否命中关键选型关键词
is_decision_task() { _wf_contains_any "$(to_lower "$1")" "${WF_DECISION_KEYWORDS[@]}"; }

# 人工确认：只在交互终端里询问，非交互（如 cron）一律视为未确认
confirm_by_human() {
  local prompt="$1" ans=""
  if [[ ! -t 0 ]]; then
    log_warn "当前为非交互环境，无法本人确认，按规则不执行。"
    return 1
  fi
  read -r -p "$prompt 输入「确认」继续，其它任意输入取消: " ans
  [[ "$ans" == "确认" ]]
}
