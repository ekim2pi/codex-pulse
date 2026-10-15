# codex-pulse

Codex（ChatGPT Plus）的额度是 **5 小时一个窗口**：窗口内用不完的额度不会累加，而窗口什么时候开始，取决于你"上一次开始用 Codex"的时刻。`codex-pulse` 就是按你指定的**每日时间点**给 Codex 发一个最小开销的"心跳"请求，把窗口在这些时刻踩出来/接续上，让你坐下来干活时总有新鲜额度。

实现只有一个 bash 脚本：cron 到点拉起 `pulse.sh fire --at HH:MM`，脚本用 `codex exec --ephemeral` 起一个**临时匿名会话**（不落盘、不出现在会话列表）发一句"只回复 OK"，然后退出。没有常驻进程、没有轮询、不需要 sudo、不依赖 Python/jq。

## 行为约定

| 情况 | 行为 |
| --- | --- |
| 到点 | 发一次心跳（即使当时额度充足，也照样发一次） |
| 到点但 5h 额度已打满（本地快照 `used_percent ≥ 99.9` 且未到重置时刻） | 跳过本次，记 `skip_limited` + 重置时刻，不打扰 Codex |
| 晚于时间点超过 120 秒（`PULSE_GRACE`） | 记 `missed` 跳过（WSL 没开机时 cron 本来也不会补跑） |
| 同一时间点被重复触发 | 记 `skipped_duplicate`，同一天同一时间点只发一次 |
| 请求失败 / 超时 | 记 `error` / `timeout`，**不重试**，等下一个时间点 |
| 与另一个心跳重叠 | 记 `skipped_locked`（flock 保护） |

每次心跳会占用一点点额度（大约相当于 1 个请求），这是这个方案的固有成本。

## 安装

```bash
cd ~/research/codex-pulse
./pulse.sh preview       # 先看看将要写进 crontab 的日程块长什么样
./pulse.sh status        # 看当前额度快照、日程、codex 路径
./pulse.sh install       # 把日程写进用户 crontab（保留你原有条目）
```

`install` 只往 `crontab -l` 的输出里追加一个托管块（`# >>> codex-pulse >>>` … `# <<< codex-pulse <<<`），你原有的 cron 任务原样保留；重复执行是幂等的。

> 注意：`install`/`uninstall` 会调用 `crontab` 读写 `/var/spool/cron/crontabs/<user>`，请在你自己的 shell 里执行（受限沙箱里读不到那个目录）。

## 改时间点

编辑 `pulse.sh` 顶部的配置块，然后重新 `./pulse.sh install`：

```bash
TIMES=("05:58" "11:00" "16:02" "21:04")   # 每天发心跳的时刻（本地时区）
PULSE_MODEL="gpt-5.6-luna"                # 心跳用的模型
PULSE_REASONING="low"                     # 推理档位，最低就是 low（不支持 minimal）
PULSE_PROMPT="只回复 OK，不要调用任何工具。"
PULSE_TIMEOUT=180                         # 单次超时（秒）
PULSE_GRACE=120                           # 准点窗口（秒）
PULSE_WORKDIR="/tmp"                      # 心跳的工作目录（不碰你的仓库）
CODEX_BIN=""                              # 留空 = 自动探测（PATH / nvm）
```

现在这四个点间隔都是 **5 小时零 2 分**：每次心跳都刚好落在上一个窗口过期之后 2 分钟，于是它顺手把新窗口开起来，额度窗口被钉在 `05:58–10:58 / 11:00–16:00 / 16:02–21:02 / 21:04–02:04` 这条线上，你随时开工都有一个刚开的窗口。间隔比 5 小时短的话，心跳只会落在窗口内部（多花一个请求），间隔长太多则窗口会断档（空出来的额度不会攒到下一段）。

只有夜间 02:04–05:58 这一段没有心跳，那时段窗口不开，你也不用它。

## 常用命令

```bash
./pulse.sh preview                 # 只打印 cron 日程块，不改任何东西
./pulse.sh status                  # 托管块 + 当前额度快照 + 最近事件
./pulse.sh now --dry-run           # 演练：打印将执行的命令与预检结论，不消耗额度
./pulse.sh now                     # 立刻发一次真实心跳（验证用）
./pulse.sh now --force             # 忽略额度预检，强制发一次（快照可能过期时用）
./pulse.sh fire --at 09:00         # cron 用的入口（含准点判定/去重/额度预检）
./pulse.sh selftest                # 本地自测（假 codex 驱动，不消耗额度）
./pulse.sh uninstall               # 从 crontab 移除托管块
```

## 日志

都在 `logs/`（已 gitignore；可随时删除，脚本会自动重建）：

| 文件 | 内容 |
| --- | --- |
| `logs/pulse.jsonl` | 每次执行一条结构化记录：事件、时间点、耗时、模型、执行前后额度、错误摘要 |
| `logs/service.log` | 同上的人类可读版本，超过 2MB 轮转，保留 3 份 |
| `logs/cron.log` | cron 侧 stdout/stderr，排查环境问题用 |
| `logs/runs/*.jsonl` | 最近 50 次心跳的原始 `--json` 事件流 |

## 验证一套新安装

```bash
./pulse.sh now --dry-run     # 1. 命令、预检是否符合预期（不花额度）
./pulse.sh now               # 2. 发一次真心跳：日志应出现 pulse_ok，且 ~/.codex/session_index.jsonl 不新增条目
./pulse.sh status            # 3. 看托管块和最近事件
```

想端到端试 cron：把某个时间点临时改成 2 分钟后的时刻 → `./pulse.sh install` → 等 2 分钟 → `tail -n 5 logs/pulse.jsonl` 应出现 `pulse_ok` → 改回正式时刻再 `install`。

已经在这台机器上验证过的部分（2026-10-16 凌晨）：自测 30 项全绿；cron 日程块的生成/幂等/卸载；心跳命令真实打到服务端并能正确识别额度上限；`--ephemeral` 跑完不在 `~/.codex/sessions` 里留下任何文件。额度打满时服务端的原话是 `You've hit your usage limit. ... try again at 1:21 AM.`（退出码 1，报错在 stdout 的 JSON 事件里），脚本会把它记成 `limited` + `reset_hint`。

## 原理细节

- **额度预检（零消耗）**：读 `~/.codex/sessions/**/rollout-*.jsonl` 最新的 5 个文件、各取尾部 256KB，用正则抓最后一条 `"primary":{...,"window_minutes":300,...}` 快照。抓不到就跳过预检、直接发心跳（失败也只记日志）。
- **匿名无感**：心跳用 `codex exec --ephemeral`，不写会话文件、不进会话列表；`-s read-only` + `-C /tmp` 保证它不会动你的仓库。
- **准点与去重**：`--at` 传入计划时刻，脚本用墙钟判断是否在 120 秒准点窗口内，并按 `(日期, 时刻)` 去重，抵御 WSL 休眠、时钟跳变导致的晚触发或重复触发。

## 已知边界

- WSL 没运行时不会触发，也不做 Windows 侧拉起（重启 Windows 后，打开终端或 Codex 即可恢复）。
- cron 服务需保持启用（本机由 systemd 管理，默认 enabled + active）。
- 无通知：所有结果只写日志（符合"无感"）。
- 请在你自己的 shell 里跑本脚本：`codex` 需要往 `CODEX_HOME`（默认 `~/.codex`）写状态文件，受限沙箱里会报 `Read-only file system (os error 30)`。
- 单次心跳的额度开销（`used_percent` 变化）会在第一次真正发成功时记进 `logs/pulse.jsonl` 的 `used_percent_before/after`，届时可据此判断是否需要换更省钱的模型。
