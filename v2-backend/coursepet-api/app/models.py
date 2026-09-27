# MARK: - ORM 模型（V1 端侧 JSON 文件 → V2 PostgreSQL 表）
# 对齐关系：
#   DataManager+Storage.swift 的 HomeworkItem/ParcelItem/LedgerEntry/Course → 这里五张表
#   所有业务表都挂 user_id 外键 —— V2 的核心增值：多用户数据隔离
from datetime import date, datetime

from sqlalchemy import Date, DateTime, ForeignKey, Numeric, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

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
    is_picked: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    owner: Mapped[User] = relationship(back_populates="parcels")


class LedgerEntry(Base):
    __tablename__ = "ledger_entries"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    amount: Mapped[float] = mapped_column(Numeric(10, 2))
    category: Mapped[str] = mapped_column(String(16))   # 餐饮/日用/学习/娱乐/交通/其他
    note: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    owner: Mapped[User] = relationship(back_populates="ledger_entries")


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
