#!/usr/bin/env bash
#
# monitor_collect.sh —— 只读的硬件监控采集：CPU / 内存 / 磁盘 / 进程 Top，超阈值输出报警行。
#   macOS：macmon（如已安装，仅记录原始输出）+ top / vm_stat / sysctl / ps / df
#   Linux：降级为 /proc/stat / /proc/meminfo / ps / free / df
#
# 原则：只读不杀进程。本脚本不调用 kill/pkill/killall，并在下方把它们屏蔽掉作为防呆。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ---------- 防呆：只读监控，禁止任何结束进程的操作 ----------
kill()    { die "monitor_collect.sh 是只读脚本，禁止 kill（参数：$*）" 9; }
pkill()   { die "monitor_collect.sh 是只读脚本，禁止 pkill（参数：$*）" 9; }
killall() { die "monitor_collect.sh 是只读脚本，禁止 killall（参数：$*）" 9; }

usage() {
  cat <<'EOF'
用法:
  monitor_collect.sh [--mode collect|report] [阈值选项] [--dry-run|--run]

模式:
  collect   采集一次快照（工作日 9/13/17/21 点由 cron 调用），追加到当天快照文件
  report    生成日报（工作日 9:00），汇总最近两个快照文件中的报警行与最新快照

选项:
  -m, --mode MODE          collect（默认）或 report
      --cpu-threshold N    CPU 使用率报警阈值，百分比（默认 85，示例值，可调）
      --mem-threshold N    内存使用率报警阈值，百分比（默认 90，示例值，可调）
      --disk-threshold N   磁盘使用率报警阈值，百分比（默认 90，示例值，可调）
      --disk-path PATH     检查哪个挂载点的磁盘（默认根目录）
      --top N              进程 Top 条数（默认 5）
      --dry-run            只打印将要运行的只读命令（默认）
      --run                真正采集（只读）
  -h, --help               显示本帮助

输出:
  报警行格式：ALERT [CPU|MEM|DISK] 当前值% >= 阈值%
  快照：examples/.state/monitor/YYYY-MM-DD.md
  日报：examples/output/monitor-daily-YYYY-MM-DD.md

约束: 只读。超阈值只报警，绝不结束任何进程；如何处理由人决定。
EOF
}

MODE="collect" CPU_TH=85 MEM_TH=90 DISK_TH=90 DISK_PATH="/" TOPN=5

while (($#)); do
  case "$1" in
    -m | --mode) need_arg "$1" "${2-}" "$#"; MODE="$2"; shift 2 ;;
    --cpu-threshold) need_arg "$1" "${2-}" "$#"; CPU_TH="$2"; shift 2 ;;
    --mem-threshold) need_arg "$1" "${2-}" "$#"; MEM_TH="$2"; shift 2 ;;
    --disk-threshold) need_arg "$1" "${2-}" "$#"; DISK_TH="$2"; shift 2 ;;
    --disk-path) need_arg "$1" "${2-}" "$#"; DISK_PATH="$2"; shift 2 ;;
    --top) need_arg "$1" "${2-}" "$#"; TOPN="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --run)
      # shellcheck disable=SC2034  # DRY_RUN 定义在 lib/common.sh，由其中的 is_dry_run 读取
      DRY_RUN=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log_error "未知参数: $1"; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in collect | report) ;; *) die "--mode 只能是 collect 或 report" 2 ;; esac
for v in "$CPU_TH" "$MEM_TH" "$DISK_TH" "$TOPN"; do
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "阈值/条数必须是数字：$v" 2
done

check_stop

OS="$(uname -s)"
MON_DIR="$WF_STATE_DIR/monitor"
TODAY="$(date '+%Y-%m-%d')"

# ---------- 采集函数（全部只读） ----------
cpu_usage() {
  if [[ "$OS" == "Darwin" ]]; then
    # 取第二次采样（第一次采样不准）；输出形如 "CPU usage: 3.3% user, 5.0% sys, 91.6% idle"
    top -l 2 -n 0 -s 1 | awk '/CPU usage/ {for (i = 1; i <= NF; i++) if ($i == "idle") idle = $(i - 1)}
      END {gsub("%", "", idle); if (idle == "") print "NA"; else printf "%.1f", 100 - idle}'
  elif [[ -r /proc/stat ]]; then
    local s1 s2
    s1="$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)"
    sleep 1
    s2="$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat)"
    awk -v a="$s1" -v b="$s2" 'BEGIN {split(a, x, " "); split(b, y, " ");
      dt = y[1] - x[1]; di = y[2] - x[2];
      if (dt <= 0) print "NA"; else printf "%.1f", (dt - di) * 100 / dt}'
  else
    echo "NA"
  fi
}

mem_usage() {
  if [[ "$OS" == "Darwin" ]]; then
    local total
    total="$(sysctl -n hw.memsize)"
    vm_stat | awk -v total="$total" '
      /page size of/            {for (i = 1; i <= NF; i++) if ($i == "of") ps = $(i + 1)}
      /Pages active/            {gsub(/\./, "", $3); a = $3}
      /Pages wired down/        {gsub(/\./, "", $4); w = $4}
      /occupied by compressor/  {gsub(/\./, "", $5); c = $5}
      END {if (total > 0 && ps > 0) printf "%.1f", (a + w + c) * ps * 100 / total; else print "NA"}'
  elif [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2}
      END {if (t > 0) printf "%.1f", (t - a) * 100 / t; else print "NA"}' /proc/meminfo
  else
    echo "NA"
  fi
}

disk_usage() {
  df -P "$DISK_PATH" | awk 'NR == 2 {gsub("%", "", $5); print $5}'
}

top_procs() {
  local out
  # 先完整捕获再截断，避免 pipefail 下 head 提前关闭管道导致 SIGPIPE
  if [[ "$OS" == "Darwin" ]]; then
    out="$(ps -Ao pid,pcpu,pmem,comm -r)"
  else
    out="$(ps -eo pid,pcpu,pmem,comm --sort=-pcpu)"
  fi
  head -n "$((TOPN + 1))" <<<"$out"
}

# 超阈值返回 0
over_threshold() {
  [[ "$1" == "NA" ]] && return 1
  awk -v v="$1" -v t="$2" 'BEGIN {exit !(v >= t)}'
}

print_plan() {
  echo "[DRY-RUN] 监控模式：$MODE；系统：$OS；阈值 CPU ${CPU_TH}% / MEM ${MEM_TH}% / DISK ${DISK_TH}%"
  if [[ "$MODE" == "report" ]]; then
    echo "[DRY-RUN] 将读取 $(wf_relpath "$MON_DIR") 中最近两个快照文件，提取 ALERT 行与最新快照"
    echo "[DRY-RUN] 将写入日报 $(wf_relpath "$WF_OUTPUT_DIR")/monitor-daily-$TODAY.md（由调度助手转给本人）"
    return 0
  fi
  if [[ "$OS" == "Darwin" ]]; then
    if have_cmd macmon; then
      echo "[DRY-RUN] 将执行: macmon pipe -s 1（仅记录原始输出）"
    else
      echo "[DRY-RUN] 未安装 macmon，跳过（只用系统自带命令）"
    fi
    echo "[DRY-RUN] 将执行: top -l 2 -n 0 -s 1   # CPU"
    echo "[DRY-RUN] 将执行: vm_stat; sysctl -n hw.memsize   # 内存"
    echo "[DRY-RUN] 将执行: ps -Ao pid,pcpu,pmem,comm -r   # 进程 Top $TOPN"
  else
    echo "[DRY-RUN] Linux 降级模式：读取 /proc/stat（采样两次）计算 CPU"
    echo "[DRY-RUN] 将读取 /proc/meminfo，并展示 free -m   # 内存"
    echo "[DRY-RUN] 将执行: ps -eo pid,pcpu,pmem,comm --sort=-pcpu   # 进程 Top $TOPN"
  fi
  echo "[DRY-RUN] 将执行: df -P $DISK_PATH   # 磁盘"
  echo "[DRY-RUN] 将追加快照到 $(wf_relpath "$MON_DIR")/$TODAY.md；超阈值输出 ALERT 行；不结束任何进程"
}

collect() {
  local cpu mem disk alerts=() a snapshot
  cpu="$(cpu_usage || echo NA)"
  mem="$(mem_usage || echo NA)"
  disk="$(disk_usage || echo NA)"

  over_threshold "$cpu" "$CPU_TH" && alerts+=("ALERT [CPU] ${cpu}% >= ${CPU_TH}%")
  over_threshold "$mem" "$MEM_TH" && alerts+=("ALERT [MEM] ${mem}% >= ${MEM_TH}%")
  over_threshold "$disk" "$DISK_TH" && alerts+=("ALERT [DISK] ${disk}% >= ${DISK_TH}% ($DISK_PATH)")

  snapshot="$(
    printf '\n## 快照 %s（%s）\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$OS"
    printf -- '- CPU：%s%%（阈值 %s%%）\n' "$cpu" "$CPU_TH"
    printf -- '- 内存：%s%%（阈值 %s%%）\n' "$mem" "$MEM_TH"
    printf -- '- 磁盘 %s：%s%%（阈值 %s%%）\n' "$DISK_PATH" "$disk" "$DISK_TH"
    if ((${#alerts[@]})); then
      printf '\n'
      for a in "${alerts[@]}"; do printf '%s\n' "$a"; done
    else
      printf '\n未超阈值。\n'
    fi
    # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 代码块标记
    printf '\n进程 Top %s（按 CPU）：\n\n```text\n%s\n```\n' "$TOPN" "$(top_procs)"
    if [[ "$OS" != "Darwin" ]] && have_cmd free; then
      # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 代码块标记
      printf '\nfree -m：\n\n```text\n%s\n```\n' "$(free -m)"
    fi
    if [[ "$OS" == "Darwin" ]] && have_cmd macmon; then
      # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 代码块标记
      printf '\nmacmon 原始输出（不参与阈值判断）：\n\n```text\n%s\n```\n' "$(macmon pipe -s 1 2>&1 || echo 'macmon 采集失败')"
    fi
  )"

  mkdir -p "$MON_DIR"
  printf '%s\n' "$snapshot" >>"$MON_DIR/$TODAY.md"
  printf '%s\n' "$snapshot"
  log_info "快照已追加到 $(wf_relpath "$MON_DIR/$TODAY.md")"
  if ((${#alerts[@]})); then
    log_warn "存在 ${#alerts[@]} 条报警（只报警，不处理进程，交由本人决定）"
  fi
}

report() {
  local files=() f out="$WF_OUTPUT_DIR/monitor-daily-$TODAY.md"
  if [[ -d "$MON_DIR" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && files+=("$f")
    done < <(find "$MON_DIR" -maxdepth 1 -type f -name '????-??-??.md' | sort | tail -n 2)
  fi
  if ((${#files[@]} == 0)); then
    log_warn "没有找到快照文件，请先运行 collect 模式"
    return 0
  fi
  mkdir -p "$WF_OUTPUT_DIR"
  {
    printf '# Mac 硬件监控日报 %s\n\n' "$TODAY"
    # shellcheck disable=SC2016  # 反引号是故意输出的 markdown 行内代码标记
    printf '数据来源：%s\n\n## 报警汇总\n\n' "$(for f in "${files[@]}"; do printf '`%s` ' "$(basename "$f")"; done)"
    grep -h '^ALERT' "${files[@]}" || echo "无报警。"
    printf '\n## 最新快照\n'
    awk '/^## 快照/ {buf = ""} {buf = buf $0 "\n"} END {printf "%s", buf}' "${files[${#files[@]} - 1]}"
    printf '\n> 说明：本日报只读生成；报警项的处理（如是否结束某个进程）由本人决定。\n'
  } >"$out"
  cat "$out"
  log_info "日报已写入 $(wf_relpath "$out")"
}

if is_dry_run; then
  print_plan
  exit 0
fi

if [[ "$MODE" == "collect" ]]; then
  collect
else
  report
fi
