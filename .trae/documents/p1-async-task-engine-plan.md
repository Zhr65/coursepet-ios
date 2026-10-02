# P1 异步任务引擎实施计划（Muse 式"关掉 App 还在干活"）

## Context

用户希望 CoursePet 的 AI 管家向 Meta Muse 的"个人智能体"形态靠拢。对照发现：审批（模式9）、长期记忆、晨报主动关怀、卡片输出均已具备，核心缺口是 **Muse 的标志能力——用户关闭 App 后 Agent 仍在后台干活**。本期实现：聊天里让 Agent 创建定时/一次性任务（"每天8点看看今天的课和DDL"、"明天15:00提醒我取论文"），服务器后台到点跑 ReAct 循环并把结果落库，iOS 打开 App 时拉取结果 + 本地通知。免签名环境无 APNs，沿用已验证的"端侧拉取 + 本地通知"模式（晨报同款）。

## 已确认的关键事实

- 服务器 `coursepet-api.service` 为 **uvicorn 单进程**（无 --workers）→ 调度循环不会重复执行，无需分布式锁；但 `Restart=always` 会中断执行中任务 → 用"**先推进 next_run_at 再执行**"的认领式防重/防漏。
- 全局刷新挂点：`CoursePetApp.swift` L53-59 `scenePhase == .active` → `NotificationManager.refreshAll()`。聊天页无独立刷新点。
- 服务器三件套读取：`AgentConfigStore.loadServerConfig()`（AgentKeychain.swift L37）。
- 端侧工具注册：`AgentTools.swift` 的 `allTools(dataManager:)` 数组 + `run(tool:argumentsJSON:)` 统一分发。
- `refreshAll()` 会被 `DataManager.onStateSaved` 等高频触发 → **任务拉取不挂 refreshAll 链**，挂 scenePhase .active + 聊天页 onAppear，60s 节流。

## 实施步骤

### 服务器端（d:\AI\CoursePet\v2-backend\coursepet-api\app\）

1. **models.py** — 新增两张 ORM（create_all 自动建表）：
   - `AgentTask`（agent_tasks）：id, user_id(index), title String(300), schedule_kind String(8) "daily"|"once", run_time String(5) "HH:MM"（daily 用）, run_at DateTime nullable（once 用）, next_run_at DateTime(index), status String(8) "active"|"done"|"cancelled", last_error String(500) nullable, created_at
   - `AgentTaskResult`（agent_task_results）：id, task_id(index), user_id(index), content String(2000), is_read bool default False, created_at
2. **agent/scheduler.py（新文件）** — `start_scheduler()`：`asyncio.create_task` 启动 while 循环（sleep 60s），module 级集合持强引用（仿 engine.py `_bg_tasks`）。每 tick：扫 `status==active and next_run_at<=utcnow()` **limit 5 串行执行**；每任务先 commit 推进 next_run_at（daily=Asia/Shanghai 明日 HH:MM 换算 UTC，`zoneinfo` 硬编码中国时区；once→status=done）再执行——重启漏跑由扫描自然补一次，重启中断由已推进防重跑。执行体：`await engine.send(user, f"[后台定时任务·自动执行] {title}\n请执行并给出简短汇报。", persist=False)`；结果截 2000 落 AgentTaskResult + FIFO 删 >20 条；LLM 失败重试 1 次后落失败结果并记 last_error；跳过 `__eval__` 用户任务。挂载：main.py `on_startup()` 尾部调用。
3. **agent/engine.py** — `stream()`/`send()` 加参数 `persist: bool = True`；False 时跳过全部 `_persist_message` 调用与 `_spawn_memory_extraction`（后台执行不污染对话历史/记忆）。
4. **agent/tools.py** — build_tools() 追加两个工具：
   - `create_task{title, schedule: daily|once, time}`：daily 时间 "HH:MM"，once "YYYY-MM-DD HH:MM"（已过时间报 ToolError）；解析→算 next_run_at→落库→`_log_write(entity="task")`→返回确认文本
   - `list_tasks`：列该用户 active 任务（标题+计划时间）
   - `perform_undo` 加 `entity == "task"` 分支：status 置 cancelled
   - `_TRACE_TEXT` 加两工具的过程标签
5. **main.py** — 三个端点（user_id 隔离照现有模式）：
   - `GET /agent/tasks`：任务列表 + 各任务未读结果数 + 最近一条结果
   - `POST /agent/tasks/read`：body `{result_ids: [...]}` 标记已读
   - `DELETE /agent/tasks/{id}`：取消任务（越权检查仿 delete_loose_doc）
6. **agent/prompts.py** — build_system_prompt 注入"进行中的定时任务"段落（查 AgentTask active；空列表整段省略，仿记忆段模式），能力清单句追加"创建/查询定时任务"。
7. **agent/eval.py** — 追加 1 条 create_task 用例（断言工具被调 + 回答含确认词）；fixture 重建不碰 agent_tasks。

### iOS 端（d:\AI\CoursePet\ios\CoursePet\）

8. **Agent/AgentRemoteClient.swift** — 照 `fetchDailyBrief`（L178-199）模式加：`fetchAgentTasks`（GET）、`markAgentTasksRead`（POST read）、`deleteAgentTask`（DELETE）；全部 401 重试 + 失败静默。
9. **Support/NotificationManager.swift + CoursePetApp.swift** — `refreshAgentTasks()`：拉未读结果→逐条发本地通知（identifier `coursepet_task_\(resultId)`，is_read 天然去重）→ UserDefaults 更新未读 badge 数；挂 scenePhase `.active` 处（refreshAll 调用旁），内部 60s 节流；聊天页 onAppear 也调一次。
10. **Agent/AgentTaskView.swift（新文件）** — 任务列表（active/已结束分段）+ 每任务结果时间线；onAppear 标已读（badge 清零）；滑动删除调 DELETE。配置读取用 `AgentConfigStore.loadServerConfig()`；xcodegen 自动纳入构建，无需改 pbxproj。
11. **Agent/AgentChatView.swift** — toolbar 加第三个 trailing ToolbarItem（bell 图标 + 未读 badge）→ NavigationLink 到 AgentTaskView；onAppear 触发 refreshAgentTasks。
12. **Agent/AgentTools.swift（端侧降级版）** — 端侧 `create_task`：daily=`UNCalendarNotificationTrigger(repeats: true)`、once=`dateMatching`，identifier 前缀 `coursepet_ondevice_`（与服务器任务不混）；端侧 `list_tasks` 读 pending 通知按前缀过滤。端侧只做提醒不做查询执行（App 关了无法跑 Agent），工具描述里如实说明。约 80 行，AgentEngine 分发无需改（走通用 run）。

## 边界与风险

- **时区**：run_time 只存 "HH:MM"，比较一律 UTC，展示换算 Asia/Shanghai；禁止依赖服务器系统时区。
- **任务风暴**：每 tick limit 5 + 串行 + engine 自带 3 次退避重试。
- **结果堆积**：插入时 FIFO 删每任务 >20 的旧结果。
- **端侧/服务器双模式**：端侧任务通知走 `coursepet_ondevice_` 前缀、服务器结果走 `coursepet_task_`，refreshAll 重建互不误删（前缀均在 coursepet_ 下，重建时 ondevice 提醒会被清掉重建——由端侧 list_tasks 数据源重建，与快递提醒同逻辑）。
- **评测**：调度器与评测 fixture 互不干扰（跳过 __eval__）。

## 验证清单

**VM 冒烟**（scp 7 个后端文件 → `sudo systemctl restart coursepet-api`）：
1. curl 登录拿 token → 聊天 "每天早上8点帮我看今天的课表和DDL" → 断言 create_task 被调、GET /agent/tasks 可见且 next_run_at 正确（UTC + 8h = 明早8点）
2. 建 "2分钟后" once 任务 → 等触发 → journalctl 看执行日志 → GET 查结果内容
3. `systemctl restart` 后确认 next_run_at 已推进、不重跑
4. POST /agent/tasks/read 后未读数归零；DELETE 后任务消失
5. 跑 POST /agent/eval 确认 31+1 条无回归（≥85 门禁）

**Appetize**：
6. 聊天建任务 → bell 图标出现 → 任务页可见任务
7. 杀 App → 服务器触发 → 重开 App → 收到本地通知 + badge → 点开标已读归零
8. 删除任务生效；清空服务器地址切端侧模式 → 建任务 → 授权通知 → 通知按点到达
