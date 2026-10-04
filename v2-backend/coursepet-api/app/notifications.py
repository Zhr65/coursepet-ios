# MARK: - 可插拔推送通道（服务器主动推送）
# 解决的痛点：任务结果 / DDL 提醒目前都是"App 开着才拉取+本地通知"，App 关着收不到。
# 设计：push_user / push_once 是调用方唯一入口，通道实现隔离在适配器里——
# 当前用 Bark（App Store 免费 App，走 Bark 自己的 APNs 证书，免 99 元/年开发者
# 账号，国内到达快）；以后有付费开发者账号换真 APNs，只改这里，调用方零改动。
# 铁律：推送是锦上添花，任何失败只记日志返回 False，绝不抛异常拖垮调用方
# （scheduler 主循环 / 同步链路 / 接口）。
import logging

import httpx
from sqlalchemy import select

logger = logging.getLogger("coursepet.notifications")

_BARK_API = "https://api.day.app/push"   # POST JSON：{device_key, title, body, group, level}
_TIMEOUT = 10.0                          # 推送网络 I/O 短超时，不占着事件循环干等


async def push_user(user_id: int, title: str, body: str, group: str = "CoursePet") -> bool:
    """给指定用户推一条（自动查用户的 Bark Key；没配直接跳过，不算失败）。"""
    # 本模块在 app 包顶层（与 scheduler 不同，不在 app.agent 子包），
    # 延迟导入必须用单点同级导入，from .. 会越过顶层包直接 ImportError
    from .database import SessionLocal
    from .models import User

    with SessionLocal() as db:
        user = db.get(User, user_id)
        key = (user.bark_key or "").strip() if user is not None else ""
    if not key:
        return False
    return await push_bark(key, title, body, group)


async def push_bark(device_key: str, title: str, body: str, group: str = "CoursePet") -> bool:
    """Bark 适配器。Bark 返回 code=200 才算送达。"""
    payload = {
        "device_key": device_key,
        "title": title[:64],
        "body": body[:220],
        "group": group,        # Bark App 内按 group 分组收纳
        "level": "active",     # 时效性通知：亮屏横幅，不静默入库
    }
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            r = await client.post(_BARK_API, json=payload)
            ok = r.status_code == 200 and r.json().get("code") == 200
            if not ok:
                logger.warning("bark push rejected: http=%s resp=%s", r.status_code, r.text[:200])
            return ok
    except Exception as exc:
        logger.warning("bark push failed: %s: %s", type(exc).__name__, exc)
        return False


async def push_once(user_id: int, kind: str, dedup_key: str,
                    title: str, body: str, group: str = "CoursePet") -> bool:
    """带防重的推送：同 (user, kind, dedup_key) 只推一次。

    防重日志在推送成功后才落库——失败下轮重试，送达了就绝不重推。
    适合 DDL 三档提醒 / 每天最多一条的告警这类"重复扫描但只想推一次"的场景。"""
    from .database import SessionLocal
    from .models import PushLog

    with SessionLocal() as db:
        exists = db.scalar(select(PushLog).where(
            PushLog.user_id == user_id, PushLog.kind == kind,
            PushLog.dedup_key == dedup_key))
    if exists is not None:
        return False
    ok = await push_user(user_id, title, body, group)
    if ok:
        with SessionLocal() as db:
            db.add(PushLog(user_id=user_id, kind=kind, dedup_key=dedup_key))
            db.commit()
    return ok
