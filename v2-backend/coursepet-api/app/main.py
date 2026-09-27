# MARK: - FastAPI 入口与路由
# V2 相对 V1 的架构故事：
#   V1：Agent 在 iOS 端跑，Key 存 Keychain，数据存本地 JSON —— 单设备、Key 在用户手里
#   V2：Agent 在服务器跑，Key 服务端持有，数据进 PostgreSQL —— 多端同步、多用户、可扩展
# 路由分三组：
#   /auth   注册登录（JWT）
#   /agent  对话（ReAct 循环，本项目的核心移植）
#   /sync   iOS 端数据上报（课表/步数/位置）
import json
from datetime import date, datetime

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from .agent.embeddings import embed
from .agent.engine import reset_history, send as agent_send, stream as agent_stream
from .agent.eval import run_eval_suite
from .agent.tools import perform_undo
from .database import Base, engine, get_db
from .models import Course, CourseDoc, EvalRun, User
from .schemas import (
    ChatIn, ChatOut, CourseIn, CoursesSyncIn, DisplayMessage, DocsIn, LocationIn,
    LoginIn, RegisterIn, StepsIn, TokenOut,
)
from .security import create_token, get_current_user, hash_password, verify_password

app = FastAPI(title="CoursePet API", version="2.0")


@app.on_event("startup")
def on_startup() -> None:
    """建表（开发期用 create_all；正式环境应换成 Alembic 迁移）"""
    Base.metadata.create_all(bind=engine)


# ── 健康检查（Appetize/穿透后的第一验证点）────────────
@app.get("/health")
def health() -> dict:
    return {"status": "ok", "service": "coursepet-api", "version": "2.0"}


# ── 认证 ──────────────────────────────────────────────
@app.post("/auth/register", response_model=TokenOut)
def register(body: RegisterIn, db: Session = Depends(get_db)) -> TokenOut:
    exists = db.scalar(select(User).where(User.username == body.username))
    if exists:
        raise HTTPException(status_code=400, detail="用户名已被占用")
    user = User(username=body.username,
                password_hash=hash_password(body.password),
                pet_name=body.pet_name)
    db.add(user)
    db.commit()
    return TokenOut(access_token=create_token(user.id), pet_name=user.pet_name)


@app.post("/auth/login", response_model=TokenOut)
def login(body: LoginIn, db: Session = Depends(get_db)) -> TokenOut:
    user = db.scalar(select(User).where(User.username == body.username))
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=401, detail="用户名或密码不对")
    return TokenOut(access_token=create_token(user.id), pet_name=user.pet_name)


# ── Agent 对话 ────────────────────────────────────────
@app.post("/agent/chat", response_model=ChatOut)
async def chat(body: ChatIn, user: User = Depends(get_current_user)) -> ChatOut:
    """一次 ReAct 完整过程：user/tool_trace/assistant 消息序列"""
    messages = await agent_send(user, body.message)
    # engine 返回的是 dataclass，转成 Pydantic 模型（两者同名不同类）
    return ChatOut(messages=[DisplayMessage(kind=m.kind, text=m.text) for m in messages])


@app.post("/agent/chat/stream")
async def chat_stream(body: ChatIn, user: User = Depends(get_current_user)) -> StreamingResponse:
    """流式对话（NDJSON）：每产生一条展示消息立即推一行 JSON，最后一行 {"done": true}。

    过程标签先到、最终回答后到——客户端边收边渲染，多轮工具调用的等待
    不再是一整块空白。iOS 端 404 时自动回落非流式 /agent/chat。"""
    async def gen():
        async for m in agent_stream(user, body.message):
            yield json.dumps({"kind": m.kind, "text": m.text}, ensure_ascii=False) + "\n"
        yield json.dumps({"done": True}) + "\n"
    return StreamingResponse(gen(), media_type="application/x-ndjson")


@app.delete("/agent/history")
def clear_history(user: User = Depends(get_current_user)) -> dict:
    reset_history(user.id)
    return {"ok": True}


@app.post("/agent/undo")
def undo(user: User = Depends(get_current_user),
         db: Session = Depends(get_db)) -> dict:
    """撤销最近一次 Agent 写入（交互原则 8）——与工具 undo_last_write 共用同一实现"""
    return {"undone": perform_undo(user, db)}


# ── Agent 评测（模式 10：评估观测）──────────────────────
@app.post("/agent/eval")
async def run_eval(user: User = Depends(get_current_user)) -> dict:
    """跑全量评测集（12 条，约 1 分钟）：专用账号 + 固定 fixture + 工具/关键词双断言。

    每条用例独立会话；结果落 eval_runs 表形成分数时间曲线——
    改 prompt / 换模型前后各跑一次，掉分即回归。"""
    return await run_eval_suite(user)


@app.get("/agent/eval/history")
def eval_history(user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)) -> list[dict]:
    """最近 10 次评测的分数曲线（不含明细，明细见 /agent/eval 返回）"""
    rows = db.scalars(
        select(EvalRun).order_by(EvalRun.id.desc()).limit(10)
    ).all()
    return [
        {
            "run_id": r.id,
            "model": r.model,
            "score": round(r.passed / r.total * 100, 1) if r.total else 0,
            "passed": r.passed,
            "total": r.total,
            "duration_ms": r.duration_ms,
            "at": r.created_at.isoformat(),
        }
        for r in rows
    ]


# ── 数据同步（iOS → 服务器）──────────────────────────
@app.post("/sync/courses")
def sync_courses(body: CoursesSyncIn, user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)) -> dict:
    """整表替换式导入课表（与 iOS OCR 导入的"确认页提交"对齐）"""
    db.query(Course).filter(Course.user_id == user.id).delete()
    for c in body.courses:
        db.add(Course(user_id=user.id, **c.model_dump()))
    if body.semester_start_date:
        try:
            user.semester_start_date = date.fromisoformat(body.semester_start_date)
        except ValueError:
            raise HTTPException(status_code=400, detail="semester_start_date 格式应为 YYYY-MM-DD")
    db.commit()
    return {"ok": True, "imported": len(body.courses)}


@app.get("/sync/courses")
def get_courses(user: User = Depends(get_current_user),
                db: Session = Depends(get_db)) -> dict:
    rows = db.scalars(select(Course).where(Course.user_id == user.id)).all()
    return {
        "semester_start_date": user.semester_start_date.isoformat() if user.semester_start_date else None,
        "courses": [
            {"name": c.name, "teacher": c.teacher, "location": c.location,
             "day_of_week": c.day_of_week, "start_time": c.start_time,
             "end_time": c.end_time, "week_parity": c.week_parity}
            for c in rows
        ],
    }


@app.post("/sync/steps")
def sync_steps(body: StepsIn, user: User = Depends(get_current_user)) -> dict:
    """步数上报：端侧采集（CoreMotion）→ 服务端聚合，Agent 工具查这里"""
    user.today_steps = body.steps
    user.steps_date = date.today()
    return {"ok": True}


@app.post("/sync/location")
def sync_location(body: LocationIn, user: User = Depends(get_current_user)) -> dict:
    """位置上报：天气工具需要经纬度调 Open-Meteo"""
    user.latitude = body.latitude
    user.longitude = body.longitude
    return {"ok": True}


@app.post("/sync/docs")
def sync_docs(body: DocsIn, user: User = Depends(get_current_user),
              db: Session = Depends(get_db)) -> dict:
    """课程资料上传（模式 7 RAG 的数据入口，预留 iOS OCR 接入）：
    文本 → 本地哈希嵌入 → pgvector。检索走 Agent 工具 search_course_materials"""
    content = body.content.strip()[:4000]
    if not content:
        raise HTTPException(status_code=400, detail="内容不能为空")
    doc = CourseDoc(user_id=user.id, title=(body.title.strip() or "未命名资料")[:120],
                    content=content, vector=embed(content))
    db.add(doc)
    db.commit()
    return {"ok": True, "doc_id": doc.id}
