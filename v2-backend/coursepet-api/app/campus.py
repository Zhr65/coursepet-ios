# MARK: - 校园数据（xllite 集成层）
# 目标：让 iOS / Android 端把 xllite 解析后的课表推到这里入库，供多端查询。
# 设计原则：
#   1. 后端永远碰不到学号+密码 —— 鉴权用 xllite 自己做（CURL 助手层封装在 xllite_client.py 的话
#      也只接收 accessToken，不接收明文凭据）。xllite 那边用户密码留在他自己 App。
#   2. 数据独立于现有 Course 表（避免破坏手动课表功能），用独立 CampusCourse 表 + 自己的接口。
#   3. 接口沿用现有 Bearer 鉴权（get_current_user），跟账本 / 邀请码一致。
#   4. 一次 sync 整体替换该学期课表（用户调一次 = 全量覆盖），简单可靠。
import json
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import Column, DateTime, Integer, String, Text, delete
from sqlalchemy.orm import Session

from .database import Base, get_db
from .security import get_current_user
from .models import User

# 复用同一个 Base，方便 alembic 后续一次性建表
router = APIRouter(prefix="/campus", tags=["campus"])


# MARK: - 数据模型（独立表，不与现有 Course 冲突）
class CampusCourse(Base):
    """xllite 同步过来的课表条目。term 维度隔离（不同学期可共存）。"""
    __tablename__ = "campus_courses"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, index=True, nullable=False)
    student_id = Column(String(64), nullable=False, comment="xllite 返的学号")
    term = Column(String(32), nullable=False, comment="学期，如 2026-2027-1")
    day = Column(String(16), nullable=False, comment="星期：星期一/二/.../日")
    slot = Column(String(32), nullable=False, comment="第几大节，如 第一大节 / 上午")
    title = Column(String(128), nullable=False, comment="课程名")
    teacher = Column(String(64), default="")
    weeks = Column(String(64), default="", comment="如 1-16周 / 单周 / 双周")
    sections = Column(String(32), default="", comment="如 1-2节")
    location = Column(String(128), default="")
    raw_json = Column(Text, default="", comment="xllite 原始 JSON 片段,留作后续解析调试")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


# MARK: - Pydantic schema
class CampusCourseIn(BaseModel):
    student_id: str = Field(..., description="xllite 返回的学号")
    term: str = Field(..., description="学期，如 2026-2027-1")
    title: str
    day: str
    slot: str
    teacher: str = ""
    weeks: str = ""
    sections: str = ""
    location: str = ""
    raw_json: str = ""


class CampusSyncIn(BaseModel):
    """App 调一次 = 全量覆盖该学期的课表（先删后插，简单可靠）"""
    student_id: str
    term: str
    courses: List[CampusCourseIn]


class CampusCourseOut(BaseModel):
    id: int
    student_id: str
    term: str
    day: str
    slot: str
    title: str
    teacher: str
    weeks: str
    sections: str
    location: str

    class Config:
        from_attributes = True


# MARK: - 路由
@router.post("/sync", summary="全量同步 xllite 课表（覆盖该学期）")
def sync_courses(
    payload: CampusSyncIn,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    """App 把 xllite 解析后的整张课表推一次；后端先删该 user+term 旧数据再批量插入。

    为啥整体替换：xllite 课表是「全量真相」，客户端不可能只发 diff；
    删+插一次事务 = 强一致，比「增量 upsert」简单可靠得多。"""
    if not payload.courses:
        # 空课表也要清掉旧的
        db.execute(
            delete(CampusCourse).where(
                CampusCourse.user_id == current.id,
                CampusCourse.term == payload.term,
            )
        )
        db.commit()
        return {"deleted": True, "inserted": 0}

    # 1) 删旧
    db.execute(
        delete(CampusCourse).where(
            CampusCourse.user_id == current.id,
            CampusCourse.term == payload.term,
        )
    )
    # 2) 插新
    for c in payload.courses:
        db.add(CampusCourse(
            user_id=current.id,
            student_id=c.student_id,
            term=c.term,
            day=c.day,
            slot=c.slot,
            title=c.title,
            teacher=c.teacher,
            weeks=c.weeks,
            sections=c.sections,
            location=c.location,
            raw_json=c.raw_json or json.dumps({"src": "xllite"}),
        ))
    db.commit()
    return {"deleted": True, "inserted": len(payload.courses)}


@router.get("/courses", response_model=List[CampusCourseOut], summary="拉取当前用户已同步的课表")
def list_courses(
    term: Optional[str] = None,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    q = db.query(CampusCourse).filter(CampusCourse.user_id == current.id)
    if term:
        q = q.filter(CampusCourse.term == term)
    return q.order_by(CampusCourse.term.desc(), CampusCourse.day, CampusCourse.slot).all()


@router.delete("/courses", summary="清空当前用户的课表（按学期）")
def clear_courses(
    term: str,
    db: Session = Depends(get_db),
    current: User = Depends(get_current_user),
):
    res = db.execute(
        delete(CampusCourse).where(
            CampusCourse.user_id == current.id,
            CampusCourse.term == term,
        )
    )
    db.commit()
    return {"deleted": res.rowcount}
