# MARK: - ORM 模型（V1 端侧 JSON 文件 → V2 PostgreSQL 表）
# 对齐关系：
#   DataManager+Storage.swift 的 HomeworkItem/ParcelItem/LedgerEntry/Course → 这里五张表
#   所有业务表都挂 user_id 外键 —— V2 的核心增值：多用户数据隔离
from datetime import date, datetime

from sqlalchemy import Date, DateTime, ForeignKey, Numeric, String, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from pgvector.sqlalchemy import Vector

from .database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(200))
    pet_name: Mapped[str] = mapped_column(String(16), default="小狼")
    # 学期开始日（周数计算的数据源；None = 未设置）
    semester_start_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    # 定位（iOS 上报，服务端调 Open-Meteo 查天气用）
    latitude: Mapped[float | None] = mapped_column(nullable=True)
    longitude: Mapped[float | None] = mapped_column(nullable=True)
    # 步数（iOS 每次启动/前台时上报；跨天自动失效）
    today_steps: Mapped[int] = mapped_column(default=0)
    steps_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    # Bark 推送 Key（App Store 免费 App Bark 的设备 Key；空串=未开启服务器主动推送）
    bark_key: Mapped[str] = mapped_column(String(100), default="")

    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    courses: Mapped[list["Course"]] = relationship(back_populates="owner", cascade="all, delete-orphan")
    homeworks: Mapped[list["Homework"]] = relationship(back_populates="owner", cascade="all, delete-orphan")
    parcels: Mapped[list["Parcel"]] = relationship(back_populates="owner", cascade="all, delete-orphan")
    ledger_entries: Mapped[list["LedgerEntry"]] = relationship(back_populates="owner", cascade="all, delete-orphan")


class Course(Base):
    __tablename__ = "courses"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(64))
    teacher: Mapped[str] = mapped_column(String(32), default="")
    location: Mapped[str] = mapped_column(String(64), default="")
    day_of_week: Mapped[int] = mapped_column()          # 1=周一 … 7=周日
    start_time: Mapped[str] = mapped_column(String(5))  # "08:00"
    end_time: Mapped[str] = mapped_column(String(5))
    week_parity: Mapped[str] = mapped_column(String(6), default="all")  # all/single/double

    owner: Mapped[User] = relationship(back_populates="courses")


class Homework(Base):
    __tablename__ = "homeworks"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    title: Mapped[str] = mapped_column(String(128))
    course_name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    is_done: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    owner: Mapped[User] = relationship(back_populates="homeworks")


class Parcel(Base):
    __tablename__ = "parcels"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    code: Mapped[str] = mapped_column(String(32))
    station: Mapped[str] = mapped_column(String(64), default="未识别驿站")
    note: Mapped[str | None] = mapped_column(String(128), nullable=True)
    tracking_no: Mapped[str | None] = mapped_column(String(32), nullable=True)  # 快递单号（可空，短信里有才存）
    is_picked: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    owner: Mapped[User] = relationship(back_populates="parcels")


class PlatformAccount(Base):
    """作业平台账号（学习通/智慧树）：服务器轮询拉作业的凭据

    密码不落明文：Fernet 对称加密后存 password_enc（密钥由 jwt_secret 派生，
    见 security.py derive_platform_key）。status 是轮询器写的健康状态：
    ok=正常 / auth_failed=登录失效需重新绑定 / error=网络或解析异常。
    (user_id, platform) 唯一：一个用户每平台只绑一个账号，重复绑定即覆盖。"""
    __tablename__ = "platform_accounts"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    platform: Mapped[str] = mapped_column(String(16))               # chaoxing / zhihuishu
    username: Mapped[str] = mapped_column(String(64))
    password_enc: Mapped[str] = mapped_column(String(500))
    status: Mapped[str] = mapped_column(String(16), default="pending")
    last_error: Mapped[str | None] = mapped_column(String(200), nullable=True)
    last_sync_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class SyncedAssignment(Base):
    """平台同步回来的作业（学习通等）：iOS 拉取合并进本地作业列表

    external_key 是平台侧作业的唯一标识（学习通=taskrefId 或 URL 参数指纹），
    (user_id, platform, external_key) 唯一 —— 重复轮询 upsert 不产生重复行；
    iOS 端以此拼 sourceKey 去重，手动加的本地作业不受影响。"""
    __tablename__ = "synced_assignments"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    platform: Mapped[str] = mapped_column(String(16))
    external_key: Mapped[str] = mapped_column(String(200))
    title: Mapped[str] = mapped_column(String(128))
    course_name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)  # 平台给的截止时间（北京语义）
    is_done: Mapped[bool] = mapped_column(default=False)            # 平台显示已提交/已完成
    updated_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now(), onupdate=func.now())


class DailyBrief(Base):
    """AI 晨报（扩展点：主动关怀）

    服务端当日生成（当日唯一，重复请求覆盖更新），iOS 端拉取后
    重排当天 07:00 的本地通知——免签名环境无 APNs，推送走"端侧拉取 + 本地通知"。
    生成失败时端侧回落到原天气模板通知，用户侧永远有晨报可看。"""
    __tablename__ = "daily_briefs"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    brief_date: Mapped[date] = mapped_column(Date, index=True)  # 晨报目标日期
    content: Mapped[str] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class ProactiveBrief(Base):
    """主动关怀的通用文案缓存（DDL 前夜建议等）

    key = 场景前缀 + 当日 + 批次内容哈希：同一天同样的作业清单重复拉取
    直接命中缓存，零 LLM 开销；LLM 失败则不落缓存，端侧回落静态文案。"""
    __tablename__ = "proactive_briefs"

    id: Mapped[int] = mapped_column(primary_key=True)
    key: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    content: Mapped[str] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class PushLog(Base):
    """服务器主动推送的防重日志：同 (user_id, kind, dedup_key) 只推一次

    kind = 事件类型（ddl / platform_alert…）；dedup_key 编码作业唯一键+档位 /
    平台+日期等（如 "chaoxing:123:6h"、"zhihuishu:auth_failed:20261004"）。
    推送成功才落一条（失败下轮重试）；唯一约束兜底防并发双推。"""
    __tablename__ = "push_logs"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    kind: Mapped[str] = mapped_column(String(24))
    dedup_key: Mapped[str] = mapped_column(String(120))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    __table_args__ = (UniqueConstraint("user_id", "kind", "dedup_key", name="uq_push_dedup"),)


class LedgerEntry(Base):
    __tablename__ = "ledger_entries"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    amount: Mapped[float] = mapped_column(Numeric(10, 2))
    category: Mapped[str] = mapped_column(String(16))   # 餐饮/日用/学习/娱乐/交通/其他
    note: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    owner: Mapped[User] = relationship(back_populates="ledger_entries")


class Memory(Base):
    """Agent 长期记忆（交互原则 6）

    每轮对话结束后由引擎后台提取"值得记住的事实"（用户目标/偏好/习惯），
    下次对话取 importance 和时间最高的 top-5 注入 system prompt。
    提取失败静默——记忆是锦上添花，绝不能影响聊天主链路。"""
    __tablename__ = "memories"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    fact: Mapped[str] = mapped_column(String(200))      # 一句话事实，如"正在备考2027考研数学"
    importance: Mapped[int] = mapped_column(default=1)  # 预留权重位（当前统一为 1）
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class AgentWrite(Base):
    """Agent 写操作流水（交互原则 8：写操作可撤销）

    每次 add_ 类写工具落库后记一笔流水；用户说"撤了它"时按流水回滚最近一次。
    只记录"新增/状态变更"，查询类工具不记。"""
    __tablename__ = "agent_writes"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    entity: Mapped[str] = mapped_column(String(16))  # homework / parcel / ledger / homework_done / task
    entity_id: Mapped[int] = mapped_column()         # 被写行的 id（homework_done = 被标记的作业 id）
    summary: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class CourseDoc(Base):
    """课程资料库（模式 7：RAG 检索）

    用户把课件/笔记文本发进来，向量化入库；检索时算余弦距离取 top-3。
    向量由本地哈希嵌入生成（256 维，见 agent/embeddings.py），存 pgvector。"""
    __tablename__ = "course_docs"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    title: Mapped[str] = mapped_column(String(128))
    content: Mapped[str] = mapped_column(String(4000))
    vector = mapped_column(Vector(256))  # pgvector 向量列，余弦检索用
    # 文件级课件：一份文件分块后每块一行，source_file 相同、chunk_index 递增；
    # 聊天里存的散条两列均为 NULL。管理页按 source_file 分组列表/整文件删除。
    source_file: Mapped[str | None] = mapped_column(String(200), nullable=True)
    chunk_index: Mapped[int | None] = mapped_column(nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class StudyPlan(Base):
    """复习计划（模式 8：规划执行）

    LLM 把"复习目标"按天拆成任务清单落库；任务同时写入 homeworks 表
    （course_name="复习计划"标记），复用现有完成跟踪与 DDL 列表展示。"""
    __tablename__ = "study_plans"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    goal: Mapped[str] = mapped_column(String(128))
    plan_json: Mapped[str] = mapped_column(String(3500), default="[]")  # 原始计划存档
    is_active: Mapped[bool] = mapped_column(default=True)  # 新计划创建时旧计划自动置 False
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class ConversationMessage(Base):
    """对话历史持久化（原 TODO V2.1）

    ReAct 的每条消息（user/assistant/tool）都写穿到 PG；引擎每次只加载
    最近 KEEP_ROUNDS 条注入上下文。服务重启、换设备登录都能续聊。"""
    __tablename__ = "conversation_messages"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    role: Mapped[str] = mapped_column(String(16))               # user / assistant / tool
    content: Mapped[str] = mapped_column(String(4000))
    tool_calls_json: Mapped[str | None] = mapped_column(String(2000), nullable=True)
    tool_call_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class AgentTask(Base):
    """Agent 异步任务（Muse 式"关掉 App 还在干活"）

    用户在聊天里让 Agent 创建的定时/一次性任务；服务器调度循环到点用
    ReAct 执行并落结果（agent_task_results）。时区约定：run_time 只存
    "HH:MM"（北京时间），比较一律换算成 UTC 的 next_run_at——禁止依赖
    服务器系统时区。认领式执行：先推进 next_run_at 再跑，服务重启
    （Restart=always 中断执行）不重跑、不双发。"""
    __tablename__ = "agent_tasks"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    title: Mapped[str] = mapped_column(String(300))              # 任务指令（原样交给 Agent 执行）
    schedule_kind: Mapped[str] = mapped_column(String(8))        # daily / once
    run_time: Mapped[str | None] = mapped_column(String(5), nullable=True)   # daily 的 "HH:MM"（北京时间）
    run_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True) # once 的目标时刻（北京时间）
    next_run_at: Mapped[datetime] = mapped_column(DateTime, index=True)      # 下次触发（UTC，调度扫描基准）
    status: Mapped[str] = mapped_column(String(8), default="active")         # active / done / cancelled
    last_error: Mapped[str | None] = mapped_column(String(500), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class AgentTaskResult(Base):
    """异步任务的执行结果流水：iOS 打开 App 时拉取未读结果 → 本地通知。

    is_read 即"未读标记"：拉取后用户进任务页才标已读，天然去重。
    每任务只保留最近 20 条（FIFO 清理见 scheduler）。"""
    __tablename__ = "agent_task_results"

    id: Mapped[int] = mapped_column(primary_key=True)
    task_id: Mapped[int] = mapped_column(index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    content: Mapped[str] = mapped_column(String(2000))
    is_read: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class EvalRun(Base):
    """Agent 评测存档（模式 10：评估观测）

    每次跑 /agent/eval 全量测试集后落一行——分数随时间的变化曲线
    就是"改 prompt / 换模型有没有变好"的证据，面试演示用。"""
    __tablename__ = "eval_runs"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)  # 触发者
    model: Mapped[str] = mapped_column(String(64))          # 当时用的 LLM 模型名
    total: Mapped[int] = mapped_column()                    # 用例总数
    passed: Mapped[int] = mapped_column()                   # 通过数
    duration_ms: Mapped[int] = mapped_column(default=0)     # 总耗时
    # 每条用例的明细 JSON：[{question, pass, tools, answer, fail_reason}]
    detail: Mapped[str] = mapped_column(String(4000), default="[]")
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())


class DailyDiscover(Base):
    """每日预生成的兴趣动态（Muse 式"打开即见"）

    scheduler 每天 08:05（北京）给每个用户生成一条落表；App 打开动态页时
    优先拉今天这条（0 等待）。每用户每天最多一条：生成前查重，幂等。"""
    __tablename__ = "daily_discovers"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    day: Mapped[date] = mapped_column(Date, index=True)     # 北京时间的"哪一天"
    topic: Mapped[str] = mapped_column(String(16))
    title: Mapped[str] = mapped_column(String(40))
    body: Mapped[str] = mapped_column(String(320))
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())