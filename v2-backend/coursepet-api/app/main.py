# MARK: - FastAPI 入口与路由
# V2 相对 V1 的架构故事：
#   V1：Agent 在 iOS 端跑，Key 存 Keychain，数据存本地 JSON —— 单设备、Key 在用户手里
#   V2：Agent 在服务器跑，Key 服务端持有，数据进 PostgreSQL —— 多端同步、多用户、可扩展
# 路由分三组：
#   /auth   注册登录（JWT）
#   /agent  对话（ReAct 循环，本项目的核心移植）
#   /sync   iOS 端数据上报（课表/步数/位置）
import hashlib
import json
from datetime import date, datetime
from zoneinfo import ZoneInfo

from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.responses import StreamingResponse
from sqlalchemy import delete, func, select, text
from sqlalchemy.orm import Session

from .agent.doc_parser import chunk_text, extract_text
from .agent.embeddings import embed
from .agent.engine import _cheap_llm, generate_discover, reset_history, send as agent_send, stream as agent_stream
from .agent.eval import run_eval_suite
from .agent.scheduler import start_scheduler
from .agent.tools import (
    _next_class, _pending_homeworks, _today_schedule, _weather, perform_undo,
)
from .agent.week import current_week_number
from .assignments import apply_sync_result, qr_start, qr_status, run_sync, status_for
from .database import Base, engine, get_db
from .models import AgentTask, AgentTaskResult, Course, CourseDoc, DailyBrief, DailyDiscover, EvalRun, Memory, Parcel, PlatformAccount, ProactiveBrief, SyncedAssignment, User
from .schemas import (
    AgentTaskOut, AssignmentsOut, AccountStatusOut, AssignmentOut, ChatIn, ChatOut, CourseIn, CoursesSyncIn, DailyBriefOut, DDLAdviceIn,
    DiscoverFeedbackIn, DisplayMessage, DocsIn, LocationIn, LoginIn, ParcelsSyncIn, ParcelsSyncOut,
    PlatformAccountIn, RegisterIn, SoulIn, StepsIn, TaskReadIn, TaskResultOut, TasksOut, TokenOut, WeeklyBriefIn,
)
from .security import create_token, decrypt_platform_password, encrypt_platform_password, get_current_user, hash_password, verify_password

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
        # course_docs 文件级课件列（RAG 课件知识库）
        conn.execute(text(
            "ALTER TABLE course_docs ADD COLUMN IF NOT EXISTS source_file VARCHAR(200)"
        ))
        conn.execute(text(
            "ALTER TABLE course_docs ADD COLUMN IF NOT EXISTS chunk_index INTEGER"
        ))

    # 异步任务调度循环（Muse 式后台执行）——建表完成后再启动扫描
    start_scheduler()


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
    messages = await agent_send(user, body.message, images=body.images,
                                calendar_context=body.calendar_context)
    # engine 返回的是 dataclass，转成 Pydantic 模型（两者同名不同类）
    return ChatOut(messages=[DisplayMessage(kind=m.kind, text=m.text) for m in messages])


@app.post("/agent/chat/stream")
async def chat_stream(body: ChatIn, user: User = Depends(get_current_user)) -> StreamingResponse:
    """流式对话（NDJSON）：每产生一条展示消息立即推一行 JSON，最后一行 {"done": true}。

    过程标签先到、最终回答后到——客户端边收边渲染，多轮工具调用的等待
    不再是一整块空白。iOS 端 404 时自动回落非流式 /agent/chat。"""
    async def gen():
        async for m in agent_stream(user, body.message, images=body.images,
                                    calendar_context=body.calendar_context):
            yield json.dumps({"kind": m.kind, "text": m.text}, ensure_ascii=False) + "\n"
        yield json.dumps({"done": True}) + "\n"
    return StreamingResponse(gen(), media_type="application/x-ndjson")


@app.delete("/agent/history")
def clear_history(user: User = Depends(get_current_user)) -> dict:
    reset_history(user.id)
    return {"ok": True}


@app.post("/agent/soul")
def save_soul(body: SoulIn, user: User = Depends(get_current_user)) -> dict:
    """App 端推送 SOUL.md 人格说明书（Muse 式灵魂文件）。
    落到 {files_root}/{user_id}/SOUL.md，对话时由 prompts.load_soul 读取注入。"""
    from .agent.prompts import soul_file_path
    path = soul_file_path(user)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body.content, encoding="utf-8")
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"SOUL.md 写入失败：{e}")
    return {"ok": True}


@app.post("/agent/undo")
def undo(user: User = Depends(get_current_user),
         db: Session = Depends(get_db)) -> dict:
    """撤销最近一次 Agent 写入（交互原则 8）——与工具 undo_last_write 共用同一实现"""
    return {"undone": perform_undo(user, db)}


# ── 兴趣动态 + 记忆管理（Muse 式"越用越懂你"）─────────
@app.post("/agent/discover")
async def discover(user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)) -> dict:
    """按用户记忆里的兴趣生成一条趣味分享。
    点赞/点踩经 /agent/discover/feedback 写回记忆表，形成反馈闭环。"""
    try:
        topic, title, body = await generate_discover(db, user)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))
    return {"topic": topic, "title": title, "body": body}


@app.get("/agent/discover/today")
def discover_today(user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)) -> dict:
    """今天的预生成动态（scheduler 每天 08:05 生成落表）。
    没有就返回 null——客户端回落到实时生成。打开即见，0 等待。"""
    today = datetime.now(ZoneInfo("Asia/Shanghai")).date()
    row = db.scalar(select(DailyDiscover).where(
        DailyDiscover.user_id == user.id, DailyDiscover.day == today))
    if row is None:
        return {"item": None}
    return {"item": {"topic": row.topic, "title": row.title, "body": row.body}}


@app.post("/agent/discover/feedback")
def discover_feedback(body: DiscoverFeedbackIn,
                      user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)) -> dict:
    """动态板块的点赞/点踩 → 记忆表（下次生成自动多推/避开该话题）"""
    fact = (f"用户对「{body.topic}」内容感兴趣（点赞了相关分享）" if body.liked
            else f"用户对「{body.topic}」推送不感兴趣（点踩）")
    db.add(Memory(user_id=user.id, fact=fact))
    db.commit()
    return {"ok": True}


@app.get("/agent/memory")
def list_memory(user: User = Depends(get_current_user),
                db: Session = Depends(get_db)) -> dict:
    """长期记忆可视化：本用户的全部记忆事实（新→旧），记忆管理页用"""
    rows = db.scalars(
        select(Memory).where(Memory.user_id == user.id)
        .order_by(Memory.id.desc())).all()
    return {"items": [{"id": m.id, "fact": m.fact} for m in rows]}


@app.delete("/agent/memory/{memory_id}")
def delete_memory(memory_id: int, user: User = Depends(get_current_user),
                  db: Session = Depends(get_db)) -> dict:
    """删除单条记忆（user_id 强制隔离，别人的记忆删不动）"""
    m = db.get(Memory, memory_id)
    if m is not None and m.user_id == user.id:
        db.delete(m)
        db.commit()
    return {"ok": True}


@app.delete("/agent/memory")
def clear_memory(user: User = Depends(get_current_user),
                 db: Session = Depends(get_db)) -> dict:
    """清空本用户全部记忆"""
    db.execute(delete(Memory).where(Memory.user_id == user.id))
    db.commit()
    return {"ok": True}


# ── Agent 评测（模式 10：评估观测）──────────────────────
@app.post("/agent/eval")
async def run_eval(user: User = Depends(get_current_user)) -> dict:
    """跑全量评测集（31 条，约 3~5 分钟）：专用账号 + 固定 fixture + 工具/关键词/反调用三重断言。

    每条用例独立会话并记录延迟/token 明细；结果落 eval_runs 表形成分数时间曲线——
    改 prompt / 换模型前后各跑一次，掉分即回归。gate.passed=False 表示跌破门禁线。"""
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


# ── 课件知识库（文件级 RAG）：上传 → 抽文本 → 分块 → 每块一行入库 ──
_ALLOWED_DOC_EXT = {"pdf", "docx", "pptx", "txt", "md"}


@app.post("/sync/docs/file")
def upload_doc_file(file: UploadFile = File(...),
                    name: str = Query("", max_length=120),
                    user: User = Depends(get_current_user),
                    db: Session = Depends(get_db)) -> dict:
    """整份课件文件入库（multipart）：服务器抽文本 + 语义分块 + 逐块嵌入。

    中文显示名走 query 的 name（multipart header 按 RFC 只放 ASCII 文件名，
    否则 python-multipart 解码易乱码）。≤8MB；块数超上限会截断并在 truncated 标出。"""
    display_name = (name or file.filename or "未命名课件").strip()[:120]
    ext = display_name.rsplit(".", 1)[-1].lower() if "." in display_name else ""
    if ext not in _ALLOWED_DOC_EXT:
        raise HTTPException(status_code=400, detail=f"不支持的文件格式：.{ext or '未知'}")
    data = file.file.read()
    if len(data) > 8 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="文件太大（上限 8MB）")
    if not data:
        raise HTTPException(status_code=400, detail="文件内容为空")

    try:
        text = extract_text(file.filename or display_name, data)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    chunks = chunk_text(text)
    truncated = len(chunk_text(text, max_chunks=None)) > len(chunks)
    for i, chunk in enumerate(chunks):
        db.add(CourseDoc(user_id=user.id, title=f"{display_name}·第{i + 1}段"[:120],
                         content=chunk, vector=embed(chunk),
                         source_file=display_name, chunk_index=i))
    db.commit()
    return {"ok": True, "file": display_name, "chunks": len(chunks), "truncated": truncated}


@app.get("/sync/docs/files")
def list_doc_files(user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)) -> dict:
    """资料库列表：文件组分块聚合成一行（管理页按文件展示/删除），散条单独列出"""
    file_rows = db.execute(
        select(CourseDoc.source_file, func.count(), func.min(CourseDoc.created_at))
        .where(CourseDoc.user_id == user.id, CourseDoc.source_file.isnot(None))
        .group_by(CourseDoc.source_file)
        .order_by(func.min(CourseDoc.created_at).desc())
    ).all()
    loose_rows = db.scalars(
        select(CourseDoc).where(CourseDoc.user_id == user.id, CourseDoc.source_file.is_(None))
        .order_by(CourseDoc.created_at.desc())
    ).all()
    return {
        "files": [
            {"name": r[0], "chunks": r[1], "created_at": r[2].isoformat() if r[2] else None}
            for r in file_rows
        ],
        "loose": [
            {"id": d.id, "title": d.title, "created_at": d.created_at.isoformat() if d.created_at else None}
            for d in loose_rows
        ],
    }


@app.delete("/sync/docs/file")
def delete_doc_file(name: str = Query(..., max_length=120),
                    user: User = Depends(get_current_user),
                    db: Session = Depends(get_db)) -> dict:
    """删除一份文件课件及其全部分块（只删当前用户的行，越权删除不存在）"""
    deleted = db.query(CourseDoc).filter(
        CourseDoc.user_id == user.id, CourseDoc.source_file == name).delete()
    db.commit()
    if not deleted:
        raise HTTPException(status_code=404, detail="文件不存在")
    return {"ok": True, "deleted": deleted}


@app.delete("/sync/docs/{doc_id}")
def delete_loose_doc(doc_id: int, user: User = Depends(get_current_user),
                     db: Session = Depends(get_db)) -> dict:
    """删除一条散条资料（聊天里存的单条笔记）；不存在或非本人 → 404"""
    doc = db.get(CourseDoc, doc_id)
    if doc is None or doc.user_id != user.id:
        raise HTTPException(status_code=404, detail="资料不存在")
    db.delete(doc)
    db.commit()
    return {"ok": True}


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


# ── 作业平台同步（学习通/智慧树 → 事务页作业）──────────
@app.post("/sync/platform-account")
def bind_platform_account(body: PlatformAccountIn,
                          user: User = Depends(get_current_user),
                          db: Session = Depends(get_db)) -> dict:
    """绑定作业平台账号：绑定即实时验证——真登录一次并试拉作业，
    账号密码错误/需要验证码当场报错，绝不把无效凭据存进库。"""
    items, complete, error = run_sync(body.platform, body.username, body.password)
    if error:
        raise HTTPException(status_code=400, detail=error)
    account = db.scalar(select(PlatformAccount).where(
        PlatformAccount.user_id == user.id,
        PlatformAccount.platform == body.platform))
    if account is None:
        account = PlatformAccount(user_id=user.id, platform=body.platform,
                                  username=body.username, password_enc="")
        db.add(account)
    account.username = body.username
    account.password_enc = encrypt_platform_password(body.password)
    apply_sync_result(db, account, items, "", complete)
    db.commit()
    return {"ok": True, "status": "ok", "count": len(items)}


@app.delete("/sync/platform-account/{platform}")
def unbind_platform_account(platform: str,
                            user: User = Depends(get_current_user),
                            db: Session = Depends(get_db)) -> dict:
    """解绑：删账号凭据 + 该平台同步来的全部作业（端侧下次拉取对齐清掉）"""
    account = db.scalar(select(PlatformAccount).where(
        PlatformAccount.user_id == user.id, PlatformAccount.platform == platform))
    if account is not None:
        db.delete(account)
    db.query(SyncedAssignment).filter(
        SyncedAssignment.user_id == user.id,
        SyncedAssignment.platform == platform).delete()
    db.commit()
    return {"ok": True}


@app.get("/sync/assignments", response_model=AssignmentsOut)
def get_assignments(user: User = Depends(get_current_user),
                    db: Session = Depends(get_db)) -> AssignmentsOut:
    """端侧拉取：平台作业全量 + 各账号健康状态（设置页展示/登录失效提示的数据源）"""
    rows = db.scalars(select(SyncedAssignment).where(
        SyncedAssignment.user_id == user.id).limit(300)).all()
    accounts = db.scalars(select(PlatformAccount).where(
        PlatformAccount.user_id == user.id)).all()
    return AssignmentsOut(
        assignments=[
            AssignmentOut(key=r.external_key, title=r.title, courseName=r.course_name,
                          dueDate=r.due_date.strftime("%Y-%m-%d %H:%M") if r.due_date else None,
                          isDone=r.is_done)
            for r in rows
        ],
        accounts=[
            AccountStatusOut(platform=a.platform, username=a.username, status=a.status,
                             lastError=a.last_error,
                             lastSyncAt=a.last_sync_at.isoformat() if a.last_sync_at else None)
            for a in accounts
        ],
    )


@app.post("/sync/assignments/refresh")
def refresh_assignments(user: User = Depends(get_current_user),
                        db: Session = Depends(get_db)) -> dict:
    """手动触发一次全部已绑定账号的同步（设置页"立即刷新"按钮；轮询循环之外的即时通道）"""
    accounts = db.scalars(select(PlatformAccount).where(
        PlatformAccount.user_id == user.id)).all()
    summary = []
    for account in accounts:
        items, complete, error = run_sync(account.platform, account.username,
                                          decrypt_platform_password(account.password_enc))
        apply_sync_result(db, account, items, error, complete)
        summary.append({"platform": account.platform, "status": status_for(error),
                        "count": len(items), "error": error or None})
    db.commit()
    return {"ok": True, "results": summary}


# ── 智慧树扫码绑定（账密登录强制滑块，扫码是唯一协议可行路径）──────────
@app.post("/sync/platform-qr/start")
def platform_qr_start(user: User = Depends(get_current_user)) -> dict:
    """生成智慧树扫码登录二维码：{qrId, image(base64 PNG), expiresIn(秒)}"""
    return qr_start(user.id)


@app.get("/sync/platform-qr/{qr_id}")
def platform_qr_status(qr_id: str, user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)) -> dict:
    """轮询扫码状态：waiting/scanned/confirmed/expired/canceled/failed。
    confirmed 即已完成绑定+首拉（服务器一次性做完，端侧刷状态即可）"""
    return qr_status(db, user.id, qr_id)


# ── 异步任务（Muse 式"关掉 App 还在干活"）──────────────
@app.get("/agent/tasks", response_model=TasksOut)
def list_agent_tasks(user: User = Depends(get_current_user),
                     db: Session = Depends(get_db)) -> TasksOut:
    """任务中心：全部任务（active 在前）+ 每任务未读数 + 结果时间线（最近在前，≤20 条）"""
    tasks = db.scalars(
        select(AgentTask).where(AgentTask.user_id == user.id)
        .order_by(AgentTask.status.asc(), AgentTask.id.desc()).limit(100)
    ).all()
    by_task: dict[int, list[AgentTaskResult]] = {}
    if tasks:
        rows = db.scalars(
            select(AgentTaskResult).where(AgentTaskResult.task_id.in_([t.id for t in tasks]))
            .order_by(AgentTaskResult.id.desc()).limit(500)
        ).all()
        for r in rows:
            by_task.setdefault(r.task_id, []).append(r)
    out = []
    for t in tasks:
        results = by_task.get(t.id, [])[:20]
        out.append(AgentTaskOut(
            id=t.id, title=t.title, scheduleKind=t.schedule_kind,
            runTime=t.run_time,
            runAt=t.run_at.strftime("%Y-%m-%d %H:%M") if t.run_at else None,
            status=t.status, lastError=t.last_error,
            unreadCount=sum(1 for r in results if not r.is_read),
            results=[TaskResultOut(id=r.id, content=r.content, isRead=r.is_read,
                                   createdAt=r.created_at.isoformat()) for r in results],
        ))
    return TasksOut(tasks=out)


@app.post("/agent/tasks/read")
def mark_tasks_read(body: TaskReadIn, user: User = Depends(get_current_user),
                    db: Session = Depends(get_db)) -> dict:
    """把拉取过的任务结果标记已读（iOS badge 去重的数据源；user_id 过滤防越权）"""
    marked = 0
    if body.result_ids:
        rows = db.scalars(
            select(AgentTaskResult).where(AgentTaskResult.user_id == user.id,
                                          AgentTaskResult.id.in_(body.result_ids))
        ).all()
        for r in rows:
            if not r.is_read:
                r.is_read = True
                marked += 1
        db.commit()
    return {"ok": True, "marked": marked}


@app.delete("/agent/tasks/{task_id}")
def cancel_agent_task(task_id: int, user: User = Depends(get_current_user),
                      db: Session = Depends(get_db)) -> dict:
    """取消任务（软删：status=cancelled，历史保留展示在"已结束"段）；非本人 → 404"""
    t = db.get(AgentTask, task_id)
    if t is None or t.user_id != user.id:
        raise HTTPException(status_code=404, detail="任务不存在")
    if t.status == "active":
        t.status = "cancelled"
        db.commit()
    return {"ok": True}


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


# ── 主动关怀（DDL 前夜分析）──────────────────────────
@app.post("/agent/ddl-advice")
async def ddl_advice(body: DDLAdviceIn,
                     user: User = Depends(get_current_user),
                     db: Session = Depends(get_db)) -> dict:
    """DDL 前夜主动分析：端侧把"明天截止"的未完成作业推上来，
    服务端一次 LLM 批量生成每条的前夜提醒（剩余时间 + 行动建议）。

    缓存：key = 批次内容哈希（当日失效）——同一天同样的清单重复拉取零 LLM 开销；
    LLM 失败返回空 advices，端侧回落静态三级轰炸文案，提醒永不缺席。"""
    items = [h for h in body.homeworks if h.title.strip()][:8]
    if not items:
        return {"advices": {}}

    key = hashlib.sha1(
        ("ddl|" + date.today().isoformat() + "|"
         + "|".join(sorted(f"{h.id}:{h.title}:{h.dueDate or ''}" for h in items))
         ).encode()
    ).hexdigest()
    cached = db.scalar(select(ProactiveBrief).where(ProactiveBrief.key == key))
    if cached is not None:
        try:
            return {"advices": json.loads(cached.content)}
        except ValueError:
            pass  # 毒缓存当作未命中重新生成

    lines = [f"- id={h.id}：《{h.title}》"
             + (f"（{h.courseName}）" if h.courseName else "")
             + (f" 截止 {h.dueDate}" if h.dueDate else "（截止时间未填）")
             for h in items]
    system = (
        "你是大学生的宠物学习管家。现在是作业截止的前夜。"
        "根据每条作业的截止时间算出剩余小时数，为每条写一句不超过45字的前夜提醒："
        "先点出剩余时间是否充裕，再给一条具体可执行的建议（如先做框架/先写实验部分）。"
        "只输出 JSON 对象：{\"<id>\": \"<提醒文案>\"}，不要输出任何其他内容。"
    )
    try:
        raw = await _cheap_llm(system, "明天截止的作业：\n" + "\n".join(lines))
        obj = json.loads(raw[raw.find("{"): raw.rfind("}") + 1])
        advices = {str(k): str(v).strip()[:120]
                   for k, v in obj.items() if isinstance(v, (str, int, float)) and str(v).strip()}
    except Exception:  # noqa: BLE001 —— LLM 抖动不阻塞接口，端侧有静态兜底
        advices = {}

    if advices:
        if cached is not None:
            cached.content = json.dumps(advices, ensure_ascii=False)
        else:
            db.add(ProactiveBrief(key=key, content=json.dumps(advices, ensure_ascii=False)))
        db.commit()
    return {"advices": advices}


# ── 主动关怀（每周学习周报）──────────────────────────
@app.post("/agent/weekly-brief")
async def weekly_brief(body: WeeklyBriefIn,
                       user: User = Depends(get_current_user),
                       db: Session = Depends(get_db)) -> dict:
    """周末学习周报：端侧汇总本周账单/作业/步数统计推上来，
    服务端一次 LLM 生成宠物口吻周报（约 150 字）。

    缓存：key = weekly|user|周起始日 —— 当周唯一，首次生成为准
    （周日当天端侧 refreshAll 触发，20:00 弹的是首版文案，同周重复拉取零 LLM 开销）；
    LLM 失败返回模板拼接文案，端侧永远有内容可排。"""
    week_start = str(body.stats.get("weekStart") or date.today().isoformat())
    key = f"weekly|u{user.id}|{week_start}"
    cached = db.scalar(select(ProactiveBrief).where(ProactiveBrief.key == key))
    if cached is not None:
        return {"brief": cached.content}

    system = (
        "你是大学生口袋宠物管家，性格元气、说话像小动物，偶尔用叠词。"
        "根据给定的本周统计 JSON（账单/作业/步数/课程），写一段不超过150字的周末周报："
        "先一句肯定本周成果（作业完成或步数），再一句消费观察（哪个分类花得最多，顺带温馨提醒），"
        "最后一句下周鼓励。挑关键说，不要罗列全部数字；用 emoji，直接输出正文。"
    )
    brief = ""
    try:
        brief = (await _cheap_llm(system, json.dumps(body.stats, ensure_ascii=False))).strip()[:480]
    except Exception:  # noqa: BLE001 —— LLM 抖动不阻塞接口，模板兜底
        brief = ""
    if not brief:
        s_stats = body.stats
        try:
            total = float(s_stats.get("ledgerTotal") or 0)
            cnt = int(s_stats.get("ledgerCount") or 0)
            done = int(s_stats.get("homeworkCompletedThisWeek") or 0)
            steps = int(s_stats.get("stepsTotal") or 0)
            top = f"，其中{s_stats['ledgerTop3'][0]}" if s_stats.get("ledgerTop3") else ""
            brief = (f"本周消费 ¥{total:.0f}（{cnt} 笔）{top}；"
                     f"完成作业 {done} 件，走了 {steps} 步。下周也一起加油哦！")
        except (TypeError, ValueError):
            brief = "这一周辛苦啦！下周也一起元气满满地加油哦！"

    db.add(ProactiveBrief(key=key, content=brief))
    db.commit()
    return {"brief": brief}
