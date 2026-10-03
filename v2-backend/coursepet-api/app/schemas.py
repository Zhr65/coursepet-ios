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
    images: list[str] = Field(default_factory=list, max_length=3)  # 拍照多模态：base64 JPEG
    calendar_context: str | None = Field(default=None, max_length=2000)  # 端侧只读的系统日历今日日程


class SoulIn(BaseModel):
    """App 端推送的 SOUL.md 人格说明书（Muse 式灵魂文件，prompt 构建时读取注入）"""
    content: str = Field(min_length=1, max_length=100_000)


class DiscoverFeedbackIn(BaseModel):
    """兴趣动态的点赞/点踩反馈（写进记忆表，影响下次选题）"""
    topic: str = Field(min_length=1, max_length=16)
    liked: bool


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


class DocsIn(BaseModel):
    """课程资料上传（模式 7 RAG）"""
    title: str = ""
    content: str = Field(min_length=1, max_length=8000)


class ParcelIn(BaseModel):
    """快递条目（iOS 事务页 → 服务器镜像）"""
    code: str
    station: str = ""
    note: str | None = None
    tracking_number: str | None = None
    is_picked: bool = False


class ParcelsSyncIn(BaseModel):
    parcels: list[ParcelIn] = Field(default_factory=list, max_length=200)


class ParcelsSyncOut(BaseModel):
    """返回合并后的完整列表：服务器上 Agent 记的快递若手机端没有，会追加进响应让端侧落库"""
    parcels: list[ParcelIn]


class DailyBriefOut(BaseModel):
    """AI 晨报（主动关怀扩展点）"""
    date: str
    brief: str


class DDLAdviceItem(BaseModel):
    """一条待提醒的作业（DDL 前夜主动分析的数据源）"""
    id: str
    title: str = Field(max_length=128)
    courseName: str | None = None
    dueDate: str | None = None  # "yyyy-MM-dd HH:mm"


class DDLAdviceIn(BaseModel):
    homeworks: list[DDLAdviceItem] = Field(default_factory=list, max_length=20)

class WeeklyBriefIn(BaseModel):
    """周末学习周报的端侧统计（账单/作业/步数等汇总数字，结构松散按需取用）"""
    stats: dict = Field(default_factory=dict)

# ── 作业平台同步（学习通/智慧树 → 事务页作业）─────────
class PlatformAccountIn(BaseModel):
    """绑定作业平台账号：绑定即触发一次实时验证登录"""
    platform: str = Field(pattern="^(chaoxing|zhihuishu)$")
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=64)


class AssignmentOut(BaseModel):
    """一条平台作业（iOS 合并进本地作业列表；key 供端侧去重）"""
    key: str                       # "chaoxing:<external_key>" 唯一键
    title: str
    courseName: str | None = None
    dueDate: str | None = None     # ISO8601（北京时间语义）
    isDone: bool = False


class AccountStatusOut(BaseModel):
    """一个已绑定账号的健康状态（设置页展示；auth_failed 提示重新绑定）"""
    platform: str
    username: str
    status: str                    # ok / auth_failed / error / pending
    lastError: str | None = None
    lastSyncAt: str | None = None


class AssignmentsOut(BaseModel):
    assignments: list[AssignmentOut] = Field(default_factory=list, max_length=300)
    accounts: list[AccountStatusOut] = Field(default_factory=list)


# ── Agent 异步任务（Muse 式"关掉 App 还在干活"）───────
class TaskResultOut(BaseModel):
    """任务执行结果（任务中心时间线条目）"""
    id: int
    content: str
    isRead: bool
    createdAt: str  # ISO8601


class AgentTaskOut(BaseModel):
    """一条定时任务（任务中心列表行）"""
    id: int
    title: str
    scheduleKind: str            # daily / once
    runTime: str | None = None   # daily 的 "HH:MM"（北京时间）
    runAt: str | None = None     # once 的 "yyyy-MM-dd HH:mm"（北京时间）
    status: str                  # active / done / cancelled
    lastError: str | None = None
    unreadCount: int = 0
    results: list[TaskResultOut] = Field(default_factory=list)  # 最近在前，≤20 条


class TasksOut(BaseModel):
    tasks: list[AgentTaskOut]


class TaskReadIn(BaseModel):
    """把拉取过的结果标记已读（badge 去重数据源）"""
    result_ids: list[int] = Field(default_factory=list, max_length=200)
