#!/usr/bin/env bash
#
# stop_all.sh —— 「停」开关示例
#   --run   写入 STOP 标志文件：其他脚本启动时（以及每一步之前）检查到它就立即退出
#   同时生成“已改内容报告”：列出最近修改过的文件，以及仍在运行的执行者 CLI 进程（只列出，不结束）
#
# 本脚本自身不检查 STOP 标志（否则无法在已停止状态下查看报告或解除）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
用法:
  stop_all.sh [--reason TEXT] [--since MIN] [--watch DIR] [--dry-run|--run]
  stop_all.sh --clear [--dry-run|--run]
  stop_all.sh --status

选项:
      --reason TEXT    叫停原因（写入 STOP 标志文件，默认「本人发出“停”指令」）
      --since MIN      报告最近 MIN 分钟内修改过的文件（默认 60）
      --watch DIR      在哪个目录下查找已改文件（默认仓库根目录）
      --clear          解除「停」：删除 STOP 标志（需 --run 才真正删除）
      --status         只查看当前是否处于「停」状态
      --dry-run        只展示将要做的事；已改内容报告是只读的，照常输出（默认）
      --run            真正写入 / 删除 STOP 标志
  -h, --help           显示本帮助

退出码: 0=成功  2=参数错误
EOF
}

REASON='本人发出“停”指令' SINCE=60 WATCH_DIR="$WF_REPO_DIR" CLEAR=0 STATUS_ONLY=0
while (($#)); do
  case "$1" in
    --reason) need_arg "$1" "${2-}" "$#"; REASON="$2"; shift 2 ;;
    --since) need_arg "$1" "${2-}" "$#"; SINCE="$2"; shift 2 ;;
    --watch) need_arg "$1" "${2-}" "$#"; WATCH_DIR="$2"; shift 2 ;;
    --clear) CLEAR=1; shift ;;
    --status) STATUS_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --run)
      # shellcheck disable=SC2034  # DRY_RUN 定义在 lib/common.sh，由其中的 is_dry_run 读取
      DRY_RUN=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log_error "未知参数: $1"; usage >&2; exit 2 ;;
  esac
done

[[ "$SINCE" =~ ^[0-9]+$ ]] || die "--since 必须是正整数（分钟）" 2
[[ -d "$WATCH_DIR" ]] || die "--watch 目录不存在: $WATCH_DIR" 2

FLAG_REL="$(wf_relpath "$WF_STOP_FLAG")"

if [[ "$STATUS_ONLY" -eq 1 ]]; then
  if [[ -f "$WF_STOP_FLAG" ]]; then
    echo "当前处于「停」状态（$FLAG_REL）："
    cat "$WF_STOP_FLAG"
  else
    echo "当前未处于「停」状态。"
  fi
  exit 0
fi

if [[ "$CLEAR" -eq 1 ]]; then
  if [[ ! -f "$WF_STOP_FLAG" ]]; then
    echo "没有 STOP 标志，无需解除。"
  elif is_dry_run; then
    echo "[DRY-RUN] 将删除 STOP 标志 $FLAG_REL（加 --run 才真正解除）"
  else
    rm -f "$WF_STOP_FLAG"
    log_info "已解除「停」：删除 $FLAG_REL"
  fi
  exit 0
fi

# ---------- 1. 写 STOP 标志 ----------
if is_dry_run; then
  echo "[DRY-RUN] 将写入 STOP 标志 $FLAG_REL（原因：$REASON）；加 --run 才真正叫停"
else
  mkdir -p "$WF_STATE_DIR"
  {
    echo "stopped_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "reason=$REASON"
  } >"$WF_STOP_FLAG"
  log_warn "已叫停：写入 $FLAG_REL。dispatch / monitor / news_relay 启动及每步之前都会检查并退出。"
fi

# ---------- 2. 已改内容报告（只读） ----------
CHANGED="$(
  cd "$WATCH_DIR" &&
    find . -type f -mmin "-$SINCE" -not -path './.git/*' -not -path '*/.state/STOP' -print | sed 's|^\./||' | sort
)"

RUNNING=""
if have_cmd pgrep; then
  # 只列出，不结束：在途任务由本人决定是否手动中止
  # 按进程名精确匹配，避免把命令行里恰好含这些字样的其他进程算进来
  RUNNING="$(pgrep -l '^(codex|claude|codebuddy)$' 2>/dev/null || true)"
fi

REPORT="$(
  printf '# 「停」报告 %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf -- '- 状态：%s\n' "$(is_dry_run && echo 'dry-run（未写入 STOP 标志）' || echo '已写入 STOP 标志')"
  printf -- '- 原因：%s\n' "$REASON"
  printf -- '- 查找范围：%s，最近 %s 分钟\n\n' "$(wf_relpath "$WATCH_DIR")" "$SINCE"
  printf '## 最近修改过的文件（已改内容）\n\n'
  if [[ -n "$CHANGED" ]]; then
    # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 行内代码标记
    while IFS= read -r f; do printf -- '- `%s`\n' "$f"; done <<<"$CHANGED"
  else
    printf '（无）\n'
  fi
  printf '\n## 仍在运行的执行者进程（仅列出，未结束）\n\n'
  if [[ -n "$RUNNING" ]]; then
    # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 代码块标记
    printf '```text\n%s\n```\n' "$RUNNING"
  else
    printf '（无，或系统不支持 pgrep）\n'
  fi
  # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 行内代码标记
  printf '\n> 恢复前请先核对以上改动；确认后执行 `./stop_all.sh --clear --run`。\n'
)"

printf '%s\n' "$REPORT"

if ! is_dry_run; then
  mkdir -p "$WF_OUTPUT_DIR"
  out="$WF_OUTPUT_DIR/stop-report-$(ts_compact).md"
  printf '%s\n' "$REPORT" >"$out"
  log_info "报告已写入 $(wf_relpath "$out")"
fi
