# MARK: - 平台作业同步的编排层：拉取 → upsert 落库 → 账号状态记录
# main.py 的绑定/刷新端点与 scheduler 的轮询循环共用这一份实现。
# 设计约束：网络 I/O 不占着数据库会话（先拉完再开短会话写）；
# 单平台失败不影响其他平台；upsert 按 (user_id, platform, external_key) 幂等。
import time
import uuid as uuid_mod
from datetime import datetime
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import PlatformAccount, SyncedAssignment
from .platforms import (
    AuthError, PlatformError, _zhs_qr_create, _zhs_qr_login, _zhs_qr_poll, sync_platform,
)
from .security import encrypt_platform_password

_TZ_BJ = ZoneInfo("Asia/Shanghai")


def run_sync(platform: str, username: str, password: str) -> tuple[list[dict], bool, str]:
    """执行一次平台拉取（纯网络，不碰库）。返回 (items, complete, error)；error=None 表示成功。"""
    try:
        items, complete = sync_platform(platform, username, password)
        return items, complete, ""
    except AuthError as e:
        return [], False, str(e) or "登录失败"
    except PlatformError as e:
        return [], False, str(e) or "平台接口异常"
    except Exception as e:  # noqa: BLE001 —— 网络抖动/解析意外都不该炸调用方
        return [], False, f"{type(e).__name__}: {e}"[:180]


def status_for(error: str) -> str:
    """error → 账号状态（前端据此提示重新绑定还是稍后再试）"""
    if not error:
        return "ok"
    return "auth_failed" if ("登录" in error or "密码" in error or "验证码" in error or "风控" in error) else "error"


def apply_sync_result(db: Session, account: PlatformAccount, items: list[dict],
                      error: str, complete: bool = True) -> None:
    """把拉取结果落库：upsert 作业 + 更新账号状态（调用方负责 commit）

    全量成功时删除平台已不再返回的陈旧行（老师撤了作业/结课清列表）；
    部分课程失败时不删——避免把拉不到的课程作业误判为已消失。"""
    db.add(account)  # 调度器在独立会话构造的游离实例并入当前会话
    existing = db.scalars(
        select(SyncedAssignment).where(
            SyncedAssignment.user_id == account.user_id,
            SyncedAssignment.platform == account.platform)).all()
    by_key = {r.external_key: r for r in existing}

    for item in items:
        row = by_key.get(item["key"])
        due = None
        if item.get("dueDate"):
            try:
                due = datetime.strptime(item["dueDate"], "%Y-%m-%d %H:%M")
            except ValueError:
                pass
        if row is not None:
            row.title = item["title"]
            row.course_name = item.get("courseName")
            row.due_date = due
            row.is_done = item.get("isDone", False)
        else:
            db.add(SyncedAssignment(
                user_id=account.user_id, platform=account.platform,
                external_key=item["key"][:200], title=item["title"][:128],
                course_name=item.get("courseName"), due_date=due,
                is_done=item.get("isDone", False)))

    if not error and complete and account.platform in ("chaoxing", "zhihuishu"):
        seen = {i["key"][:200] for i in items}
        for row in existing:
            if row.external_key not in seen:
                db.delete(row)

    account.status = status_for(error)
    account.last_error = error[:200] if error else None
    account.last_sync_at = datetime.now(_TZ_BJ).replace(tzinfo=None)


# ── 智慧树扫码绑定（账密登录强制滑块，扫码是唯一协议可行路径）──────────
# 二维码会话存进程内存（单 worker 部署，与 scheduler 同进程）：qrId → 会话快照。
# 5 分钟 TTL；服务重启后旧 qrId 自然失效，端侧重新 start 即可。
_QR_TTL = 300
_QR_PENDING: dict[str, dict] = {}


def _qr_gc() -> None:
    now = time.time()
    for k in [k for k, v in _QR_PENDING.items() if now - v["created"] > _QR_TTL]:
        _QR_PENDING.pop(k, None)


def qr_start(user_id: int) -> dict:
    """生成扫码登录二维码。返回 {qrId, image(base64 PNG), expiresIn(秒)}"""
    _qr_gc()
    sess, token, img = _zhs_qr_create()
    qr_id = uuid_mod.uuid4().hex
    _QR_PENDING[qr_id] = {"user_id": user_id, "sess": sess, "token": token,
                          "created": time.time()}
    return {"qrId": qr_id, "image": img, "expiresIn": _QR_TTL}


def qr_status(db: Session, user_id: int, qr_id: str) -> dict:
    """轮询扫码状态；确认登录即完成绑定 + 首次拉取（一步到位，端侧零额外请求）"""
    _qr_gc()
    p = _QR_PENDING.get(qr_id)
    if p is None or p["user_id"] != user_id:
        return {"status": "expired", "message": "二维码已失效，请重新获取"}

    def _done(status: str, message: str, **extra) -> dict:
        _QR_PENDING.pop(qr_id, None)
        return {"status": status, "message": message, **extra}

    try:
        info = _zhs_qr_poll(p["sess"], p["token"])
    except PlatformError as e:
        return {"status": "waiting", "message": str(e) or "网络抖动，继续等待"}
    raw = int(info.get("status", -99))
    if raw == 1:
        once = info.get("oncePassword")
        if not once:
            return _done("failed", "智慧树未返回登录凭据，请重试")
        try:
            cookie_json, nickname = _zhs_qr_login(p["sess"], str(once))
        except (AuthError, PlatformError) as e:
            return _done("failed", str(e) or "智慧树登录失败，请重试")
        count = _bind_zhihuishu(db, user_id, nickname, cookie_json)
        return _done("confirmed", f"绑定成功，已同步 {count} 条作业", count=count)
    if raw == 0:
        return {"status": "scanned", "message": "已扫描，请在手机上确认"}
    if raw == 2:
        return _done("expired", "二维码已过期，请重新获取")
    if raw == 3:
        return _done("canceled", "已取消登录")
    if raw == -99:
        return {"status": "expired", "message": "二维码状态异常，请重新获取"}
    return {"status": "waiting", "message": info.get("msg") or "等待扫码"}


def _bind_zhihuishu(db: Session, user_id: int, nickname: str, cookie_json: str) -> int:
    """扫码成功落库：cookie 加密存 password_enc（与账密绑定同一存储位）+ 首拉作业"""
    account = db.scalar(select(PlatformAccount).where(
        PlatformAccount.user_id == user_id, PlatformAccount.platform == "zhihuishu"))
    if account is None:
        account = PlatformAccount(user_id=user_id, platform="zhihuishu",
                                  username=nickname, password_enc="")
        db.add(account)
    account.username = nickname
    account.password_enc = encrypt_platform_password(cookie_json)
    items, complete, error = sync_platform("zhihuishu", nickname, cookie_json)
    apply_sync_result(db, account, items, error, complete)
    db.commit()
    return len(items)
