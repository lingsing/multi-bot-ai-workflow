# 例行任务排期与周末停休

## 1. 排期总表

所有例行任务**只在工作日（周一至周五）运行**，周六、周日停休。

| 任务 | 时间 | 脚本 | 产出 | 边界 |
|---|---|---|---|---|
| a) Mac 硬件监控 · 采集 | 9:00、13:00、17:00、21:00 | `monitor_collect.sh --mode collect --run` | 当天快照文件；超阈值输出 `ALERT` 行 | 只读，不杀进程 |
| a) Mac 硬件监控 · 日报 | 9:00（采集后） | `monitor_collect.sh --mode report --run` | 日报：报警汇总 + 最新快照 | 只读 |
| b) 新闻早报 | 工作日 9:30（北京时间，可在 crontab 中修改） | `news_relay.sh --mode brief --run` | 当日要闻 + 分析 + 核对，含未核实清单 | 网页抓取用 `codex --search exec` |
| b) 重大事件提醒 | 10:00、14:00、18:00、22:00 | `news_relay.sh --mode alert --run` | 只列重大事件；没有就输出「无重大事件」 | 同上 |
| c) 研究类接力 | 跟随新闻流程，或按需手动触发 | `news_relay.sh --topic "…" --run` | 新闻 → 分析 → 市场核对 | 只分析不下单 |
| d) 周末 | 周六、周日 | — | — | 全部停休 |

日报与提醒产出后，由调度助手转给本人。投递环节不在示例范围内。

## 2. 一天的时间线（工作日）

```text
09:00  硬件采集 → 硬件日报
09:30  新闻早报（北京时间，可在 crontab 中修改）
10:00  重大事件提醒
13:00  硬件采集
14:00  重大事件提醒
17:00  硬件采集
18:00  重大事件提醒
21:00  硬件采集
22:00  重大事件提醒
```

## 3. cron 写法

完整示例见 [`examples/crontab.example`](../examples/crontab.example)，要点：

```cron
# 分 时 日 月 星期（1-5 = 周一至周五）
0 13,17,21 * * 1-5     cd <REPO>/examples && ./is_workday.sh -q && ./monitor_collect.sh --mode collect --run
0 9 * * 1-5            cd <REPO>/examples && ./is_workday.sh -q && ./monitor_collect.sh --mode collect --run && ./monitor_collect.sh --mode report --run
0 10,14,18,22 * * 1-5  cd <REPO>/examples && ./is_workday.sh -q && ./news_relay.sh --mode alert --run
```

- 9:00 的采集和日报写在同一条里，保证日报包含当天第一个快照。
- 日报汇总“最近两个快照文件”，所以周一的日报会覆盖上周五的快照，不受周末空档影响。
- cron 中 `%` 有特殊含义，示例命令中刻意没有使用 `date +%F` 之类的写法。

## 4. 周末停休

**为什么**：省用量。周末不需要工作节奏的监控和提醒，例行任务占用的额度留给真正需要的手动任务。

**怎么实现（双保险）**：

1. cron 星期字段只写 `1-5`，周末根本不会触发。
2. 每条命令前用 `is_workday.sh -q` 再判断一次：周一至周五返回 0，周六日返回 1，`&&` 之后的任务不会执行。

第二层看似多余，但它是一个**单独的判断点**：将来接入节假日与调休表时，只需修改 `is_workday.sh`，不必改动每条 cron。

**测试**：

```bash
./is_workday.sh --date 2026-11-13; echo $?   # 周五 → 0
./is_workday.sh --date 2026-11-14; echo $?   # 周六 → 1
```

**代价与应对**：周末发生的重大事件要到周一 10:00 的提醒才会出现；确有需要时可以手动运行 `./news_relay.sh --mode alert --run`。

## 5. 与「停」的关系

STOP 标志优先于排期：即使是工作日、到了触发时刻，只要 STOP 标志存在，`monitor_collect.sh` 与 `news_relay.sh` 都会在启动时以退出码 3 退出。`is_workday.sh` 本身是纯判断，不检查 STOP。

## 6. 尚未处理

- 法定节假日与调休
- 时区（cron 按本机时区执行）
- 本机休眠或关机期间错过的触发不会补跑
