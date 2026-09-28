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
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from .agent.embeddings import embed
from .agent.engine import _cheap_llm, reset_history, send as agent_send, stream as agent_stream
from .agent.eval import run_eval_suite
from .agent.tools import (
    _next_class, _pending_homeworks, _today_schedule, _weather, perform_undo,
)
from .agent.week import current_week_number
from .database import Base, engine, get_db
from .models import Course, CourseDoc, DailyBrief, EvalRun, Memory, Parcel, User
from .schemas import (
    ChatIn, ChatOut, CourseIn, CoursesSyncIn, DailyBriefOut, DisplayMessage, DocsIn, LocationIn,
    LoginIn, ParcelsSyncIn, ParcelsSyncOut, RegisterIn, StepsIn, TokenOut,
)
from .security import create_token, get_current_user, hash_password, verify_password

app = FastAPI(title="CoursePet API", version="2.0")


@app.on_event("startup")
def on_startup() -> None:
    """建表 + 轻量列迁移（开发期用 create_all；正式环境应换成 Alembic 迁移）"""
    Base.metadata.create_all(bind=engine)
    # parcels 加列（老库升级；PG 11+ 支持 ADD COLUMN IF NOT EXISTS，幂等）
    with engine.begin() as conn:
        conn.execute(text(
            "ALTER TABLE parcels ADD COLUMN IF NOT EXISTS tracking_no VARCHAR(32)"
        ))


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


@app.post("/sync/parcels", response_model=ParcelsSyncOut)
def sync_parcels(body: ParcelsSyncIn, user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)) -> ParcelsSyncOut:
    """快递列表同步（数据同源原则）：手机端整表上推，服务器 Agent 记的快递合并保留。

    合并规则：服务器原有记录里，取件码+驿站 对不上手机列表的（=Agent 在聊天里
    记的、手机端还没有的），追加进结果一并返回——端侧把这条落库，双端收敛一致。"""
    phone_keys = {(p.code, p.station) for p in body.parcels}
    orphans = [o for o in db.scalars(select(Parcel).where(Parcel.user_id == user.id)).all()
               if (o.code, o.station) not in phone_keys]
    db.query(Parcel).filter(Parcel.user_id == user.id).delete()
    for p in body.parcels:
        db.add(Parcel(user_id=user.id, code=p.code, station=p.station or "未识别驿站",
                      note=p.note, tracking_no=p.tracking_number, is_picked=p.is_picked))
    merged = list(body.parcels) + [
        ParcelIn(code=o.code, station=o.station, note=o.note,
                 tracking_number=o.tracking_no, is_picked=o.is_picked)
        for o in orphans
    ]
    for o in orphans:
        db.add(Parcel(user_id=user.id, code=o.code, station=o.station,
                      note=o.note, tracking_no=o.tracking_no, is_picked=o.is_picked))
    db.commit()
    return ParcelsSyncOut(parcels=merged)


# ── 主动关怀（AI 晨报）────────────────────────────────
@app.get("/agent/daily-brief", response_model=DailyBriefOut)
async def daily_brief(target: date | None = None,
                      user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)) -> DailyBriefOut:
    """生成当日晨报：课表 + DDL + 天气 + 待取快递 + 长期记忆 → 宠物口吻 2~3 句。

    当日唯一（重复请求命中当日缓存直接返回）；LLM 失败时降级为
    模板拼接文案——端侧永远有内容可排，天气模板通知照常兜底。"""
    day = target or date.today()
    cached = db.scalar(select(DailyBrief).where(DailyBrief.user_id == user.id,
                                                DailyBrief.brief_date == day))
    if cached is not None:
        return DailyBriefOut(date=day.isoformat(), brief=cached.content)

    # 汇总素材（复用工具实现：它们返回的就是模型能读懂的文本）
    schedule = await _today_schedule({}, user, db)
    homework = await _pending_homeworks({}, user, db)
    weather = await _weather({}, user, db)
    parcel_count = db.scalar(
        select(func.count()).select_from(Parcel)
        .where(Parcel.user_id == user.id, Parcel.is_picked.is_(False))
    ) or 0
    week = current_week_number(user.semester_start_date)
    memories = db.scalars(
        select(Memory).where(Memory.user_id == user.id)
        .order_by(Memory.id.desc()).limit(3)
    ).all()
    memory_text = "；".join(m.fact for m in memories) if memories else "暂无长期记忆"

    system = (
        "你是大学生口袋宠物管家，性格元气、说话像小动物，偶尔用叠词。"
        "根据给定的课表/作业/天气/快递/记忆素材，写一段不超过60字的早安晨报："
        "先一句天气或课表提醒，再一句最要紧的事（DDL/取件），最后一句鼓励。"
        "不要罗列全部信息，只挑最关键的；不要用 emoji 以外的符号标记；直接输出正文。"
    )
    user_prompt = (
        f"目标日期：{day.isoformat()}（学期第{week or '?'}周）\n"
        f"今日课表：{schedule}\n未完成作业：{homework}\n"
        f"天气：{weather}\n待取快递：{parcel_count} 个\n"
        f"关于主人的记忆：{memory_text}"
    )
    brief = ""
    try:
        brief = (await _cheap_llm(system, user_prompt)).strip()[:500]
    except Exception:  # noqa: BLE001 —— LLM 抖动不阻塞接口，模板兜底
        brief = ""
    if not brief:
        first_line = schedule.splitlines()[-1] if "\n" in schedule else schedule
        brief = f"{weather} {first_line}".strip() or "今天也要元气满满哦！"

    if cached is None:
        db.add(DailyBrief(user_id=user.id, brief_date=day, content=brief))
    else:
        cached.content = brief
    db.commit()
    return DailyBriefOut(date=day.isoformat(), brief=brief)
