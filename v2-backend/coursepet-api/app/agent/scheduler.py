# MARK: - 异步任务调度器（Muse 式"关掉 App 还在干活"）
# 聊天里让 Agent 创建的定时/一次性任务（agent_tasks 表）由这里到点执行：
#   每 60 秒扫一次表 → 认领到点任务（先推进调度位再执行，防重启重跑）
#   → 交给 ReAct 引擎跑一遍（persist=False，不写聊天历史、不提取记忆）
#   → 结果截断落 agent_task_results，iOS 打开 App 拉取 + 本地通知。
# 时区约定：run_time 是北京时间 "HH:MM"，next_run_at 统一存 UTC——
# 禁止依赖服务器系统时区（云 VM 通常是 UTC）。
import asyncio
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import select

from ..assignments import apply_sync_result, run_sync
from ..database import SessionLocal
from ..models import AgentTask, AgentTaskResult, PlatformAccount, User
from ..security import decrypt_platform_password
from . import engine

logger = logging.getLogger("coursepet.scheduler")

_TZ_BJ = ZoneInfo("Asia/Shanghai")   # 任务时刻语义固定为北京时间
_UTC = timezone.utc

SCAN_INTERVAL = 60   # 扫描周期（秒）
_PER_TICK_LIMIT = 5  # 一轮最多串行执行 5 个到点任务（单 worker，避免并发轰炸 LLM）
_RESULT_MAX = 2000   # 单条结果截断（与 content 列宽对齐）
_RESULT_KEEP = 20    # 每任务结果 FIFO 上限

# 后台循环强引用（asyncio 只持弱引用，不拿住会被 GC 掉，仿 engine._bg_tasks）
_bg_tasks: set[asyncio.Task] = set()


def start_scheduler() -> None:
    """FastAPI on_startup 挂载：fire-and-forget 启动扫描循环"""
    t = asyncio.create_task(_run_loop())
    _bg_tasks.add(t)
    t.add_done_callback(_bg_tasks.discard)
    d = asyncio.create_task(_daily_discover_loop())
    _bg_tasks.add(d)
    d.add_done_callback(_bg_tasks.discard)
    a = asyncio.create_task(_assignment_sync_loop())
    _bg_tasks.add(a)
    a.add_done_callback(_bg_tasks.discard)
    logger.info("agent task scheduler started (daily discover + assignment sync included)")


async def _run_loop() -> None:
    while True:
        try:
            await _tick()
        except Exception:
            logger.exception("agent task scheduler tick failed")
        await asyncio.sleep(SCAN_INTERVAL)


async def _tick() -> None:
    for _ in range(_PER_TICK_LIMIT):
        claimed = _claim_next()
        if claimed is None:
            return
        task_id, user_id, title = claimed
        await _run_one(task_id, user_id, title)


def _claim_next() -> tuple[int, int, str] | None:
    """认领一个到点任务：先 commit 推进调度位，再返回信息去执行。

    认领先于执行：执行中途进程被杀（Restart=always），任务也不会重复跑、
    不会双发结果（最多丢当次结果）。daily 推进到下一个 run_time（北京时间
    换算 UTC），once 直接置 done。"""
    now_utc = datetime.now(_UTC).replace(tzinfo=None)
    with SessionLocal() as db:
        task = db.scalars(
            select(AgentTask)
            .where(AgentTask.status == "active", AgentTask.next_run_at <= now_utc)
            .order_by(AgentTask.next_run_at)
            .limit(1)
        ).first()
        if task is None:
            return None
        task_id, user_id, title = task.id, task.user_id, task.title
        if task.schedule_kind == "daily":
            task.next_run_at = next_daily_run(task.run_time or "08:00")
        else:
            task.status = "done"
        db.commit()
        return task_id, user_id, title


def bj_to_utc(dt_bj: datetime) -> datetime:
    """北京时间（naive）→ UTC（naive）：与 next_run_at 的存储约定一致"""
    return dt_bj.replace(tzinfo=_TZ_BJ).astimezone(_UTC).replace(tzinfo=None)


def next_daily_run(hhmm: str) -> datetime:
    """daily 任务的下次调度时刻：北京时间今天/明天的 HH:MM → UTC naive"""
    hh, mm = hhmm.split(":")[:2]
    now_bj = datetime.now(_TZ_BJ)
    candidate = now_bj.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
    if candidate <= now_bj:
        candidate += timedelta(days=1)
    return bj_to_utc(candidate)


async def _run_one(task_id: int, user_id: int, title: str) -> None:
    """执行单个任务：跑一遍 ReAct（不落历史/不提取记忆），结果落任务结果通道"""
    with SessionLocal() as db:
        user = db.get(User, user_id)
        if user is None:
            return
        if user.username == "__eval__":
            return  # 评测账号不跑后台任务，避免搅动 fixture
        # user 游离会话后列属性仍可读；engine 内部自管数据库会话

    prompt = f"[后台定时任务·自动执行] {title}\n请执行并给出简短汇报。"
    content, error = "", ""
    for _ in range(2):  # LLM 抖动重试 1 次（与引擎自带退避互补）
        try:
            msgs = await engine.send(user, prompt, persist=False)
            content = "".join(m.text for m in msgs if m.kind == "assistant").strip()
            if content:
                error = ""
                break
            error = "模型空回复"
        except Exception as exc:
            error = f"{type(exc).__name__}: {exc}"
    if not content:
        content = f"这次没跑成：{error}"

    _save_result(task_id, user_id, content, error[:500] if error else None)


def _save_result(task_id: int, user_id: int, content: str, error: str | None) -> None:
    """结果落库（独立会话）+ 记录 last_error + 结果 FIFO（每任务只留最近 20 条）"""
    with SessionLocal() as db:
        db.add(AgentTaskResult(task_id=task_id, user_id=user_id,
                               content=content[:_RESULT_MAX], is_read=False))
        task = db.get(AgentTask, task_id)
        if task is not None:
            task.last_error = error
        stale = db.scalars(
            select(AgentTaskResult)
            .where(AgentTaskResult.task_id == task_id)
            .order_by(AgentTaskResult.id.desc())
            .offset(_RESULT_KEEP)
        ).all()
        for row in stale:
            db.delete(row)
        db.commit()


# ── 作业平台轮询（学习通等：每 30 分钟拉一次新作业）─────

_ASSIGN_SYNC_INTERVAL = 30 * 60   # 轮询周期：平台作业频次低，30 分钟足够灵敏


async def _assignment_sync_loop() -> None:
    """定时给所有已绑定的作业平台账号拉作业（user 之间互相隔离，单账号失败不影响别人）。

    网络 I/O 丢线程池（asyncio.to_thread），不阻塞事件循环；
    落库走独立短会话（拉完才写，不在网络等待中占连接）。"""
    await asyncio.sleep(90)  # 启动后 90 秒先跑一轮：部署完不用等半小时
    while True:
        try:
            await _sync_all_platform_accounts()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("assignment sync loop crashed")
        await asyncio.sleep(_ASSIGN_SYNC_INTERVAL)


async def _sync_all_platform_accounts() -> None:
    with SessionLocal() as db:
        accounts = db.scalars(select(PlatformAccount)).all()
        # 先把凭据快照出来，网络请求不占数据库会话
        jobs = [(a.user_id, a.platform, a.username, a.password_enc) for a in accounts]
    for user_id, platform, username, password_enc in jobs:
        try:
            password = decrypt_platform_password(password_enc)
        except Exception:
            logger.exception("decrypt platform password failed (user %s)", user_id)
            continue
        try:
            items, complete, error = await asyncio.to_thread(
                run_sync, platform, username, password)
        except Exception:
            logger.exception("platform sync failed (user %s, %s)", user_id, platform)
            continue
        with SessionLocal() as db:
            account = db.scalar(select(PlatformAccount).where(
                PlatformAccount.user_id == user_id,
                PlatformAccount.platform == platform))
            if account is None:
                continue  # 轮询间隙用户解绑了
            apply_sync_result(db, account, items, error, complete)
            db.commit()


# ── 每日兴趣动态预生成（Muse 式"打开即见"）─────────────

_DISCOVER_TIME = "08:05"   # 北京时间每天生成，用户上班/上课路上打开就有


async def _daily_discover_loop() -> None:
    """每天 _DISCOVER_TIME 给所有用户预生成一条兴趣动态。

    任何失败（LLM/DB）都静默跳过——锦上添花的功能绝不能拖垮主调度循环。
    注意：next_daily_run 返回 naive datetime（供 agent_tasks 落库用），
    这里不能用它做 aware 时间相减，自行计算 aware 的下一次运行时刻。"""
    # 启动后 60 秒先补跑一次：部署当天不用等到明天 8 点；幂等（今天已生成自动跳过）
    await asyncio.sleep(60)
    try:
        await _generate_daily_discover()
    except Exception:
        logger.exception("daily discover catch-up failed")
    while True:
        try:
            now_bj = datetime.now(_TZ_BJ)
            hh, mm = _DISCOVER_TIME.split(":")
            run_at = now_bj.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
            if run_at <= now_bj:
                run_at += timedelta(days=1)
            await asyncio.sleep((run_at - now_bj).total_seconds())
            await _generate_daily_discover()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("daily discover loop crashed")
            await asyncio.sleep(300)


async def _generate_daily_discover() -> None:
    """给全部用户逐个生成今天的动态（每用户每天幂等一条；单用户失败不影响别人）"""
    from ..models import DailyDiscover
    today = datetime.now(_TZ_BJ).date()
    with SessionLocal() as db:
        users = db.scalars(select(User)).all()
        for u in users:
            try:
                exists = db.scalar(select(DailyDiscover).where(
                    DailyDiscover.user_id == u.id, DailyDiscover.day == today))
                if exists is not None:
                    continue
                topic, title, body = await engine.generate_discover(db, u)
                db.add(DailyDiscover(user_id=u.id, day=today,
                                     topic=topic, title=title, body=body))
                db.commit()
            except Exception:
                db.rollback()
                logger.exception("daily discover generate failed for user %s", u.id)
