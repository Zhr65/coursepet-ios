# MARK: - Pydantic 模型（请求/响应的数据契约，自动校验 + 自动生成 API 文档）
from datetime import datetime

from pydantic import BaseModel, Field


# ── 认证 ──────────────────────────────────────────────
class RegisterIn(BaseModel):
    username: str = Field(min_length=2, max_length=32)
    password: str = Field(min_length=6, max_length=64)
    pet_name: str = Field(default="小狼", max_length=16)


class LoginIn(BaseModel):
    username: str
    password: str


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    pet_name: str


# ── Agent 对话 ────────────────────────────────────────
class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=2000)


class DisplayMessage(BaseModel):
    """一条展示消息：kind = user / assistant / tool_trace / error"""
    kind: str
    text: str


class ChatOut(BaseModel):
    messages: list[DisplayMessage]


# ── 数据同步（iOS → 服务器）──────────────────────────
class CourseIn(BaseModel):
    name: str
    teacher: str = ""
    location: str = ""
    day_of_week: int = Field(ge=1, le=7)
    start_time: str  # "08:00"
    end_time: str
    week_parity: str = "all"


class CoursesSyncIn(BaseModel):
    courses: list[CourseIn]
    semester_start_date: str | None = None  # "2026-08-31"，可随课表一起上报


class StepsIn(BaseModel):
    steps: int = Field(ge=0, le=100000)


class LocationIn(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
