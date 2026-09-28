# MARK: - ORM 模型（V1 端侧 JSON 文件 → V2 PostgreSQL 表）
# 对齐关系：
#   DataManager+Storage.swift 的 HomeworkItem/ParcelItem/LedgerEntry/Course → 这里五张表
#   所有业务表都挂 user_id 外键 —— V2 的核心增值：多用户数据隔离
from datetime import date, datetime

from sqlalchemy import Date, DateTime, ForeignKey, Numeric, String, func
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
    entity: Mapped[str] = mapped_column(String(16))  # homework / parcel / ledger / homework_done
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
