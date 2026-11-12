#!/usr/bin/env bash
#
# is_workday.sh —— 周末停休判断：周一至周五返回 0，周六日返回 1。
# 用于 cron 中作为前置条件：./is_workday.sh --quiet && ./其他任务.sh --run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
用法:
  is_workday.sh [--date YYYY-MM-DD] [--quiet] [--dry-run|--run]

说明:
  判断某天是否为工作日（周一至周五）。周末例行任务停休，以节省用量。
  本脚本只读、无副作用：--dry-run 与 --run 行为相同，仅为与其他脚本保持一致的参数习惯。
  本脚本是纯判断函数，不检查 STOP 标志（STOP 由被调用的任务脚本自行检查）。
  暂不处理法定节假日与调休（见 docs/schedules.md 路线图）。

选项:
  -d, --date YYYY-MM-DD   判断指定日期（默认今天），便于测试
  -q, --quiet             不输出文字，只返回退出码
      --dry-run | --run   兼容参数，行为相同
  -h, --help              显示本帮助

退出码: 0=工作日  1=周末（停休）  2=参数或日期错误

示例:
  ./is_workday.sh --date 2026-11-13; echo $?   # 周五 → 0
  ./is_workday.sh --date 2026-11-14; echo $?   # 周六 → 1
EOF
}

DATE_STR="" QUIET=0
while (($#)); do
  case "$1" in
    -d | --date) need_arg "$1" "${2-}" "$#"; DATE_STR="$2"; shift 2 ;;
    -q | --quiet) QUIET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --run)
      # shellcheck disable=SC2034  # DRY_RUN 定义在 lib/common.sh，由其中的 is_dry_run 读取
      DRY_RUN=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log_error "未知参数: $1"; usage >&2; exit 2 ;;
  esac
done

# 返回 ISO 星期几：1=周一 … 7=周日。兼容 GNU date 与 BSD/macOS date。
day_of_week() {
  local d="$1"
  if [[ -z "$d" ]]; then
    date '+%u'
    return 0
  fi
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  date -d "$d" '+%u' 2>/dev/null && return 0              # GNU date (Linux)
  date -j -f '%Y-%m-%d' "$d" '+%u' 2>/dev/null && return 0 # BSD date (macOS)
  return 1
}

if ! dow="$(day_of_week "$DATE_STR")"; then
  die "无法解析日期 '$DATE_STR'，格式应为 YYYY-MM-DD" 2
fi

label="${DATE_STR:-今天}"
if [[ "$dow" -ge 1 && "$dow" -le 5 ]]; then
  [[ "$QUIET" -eq 1 ]] || echo "$label 是工作日（星期 $dow），例行任务照常执行。"
  exit 0
fi

[[ "$QUIET" -eq 1 ]] || echo "$label 是周末（星期 $dow），例行任务停休。"
exit 1
