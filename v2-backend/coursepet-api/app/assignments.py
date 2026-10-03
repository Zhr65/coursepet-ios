# MARK: - 平台作业同步的编排层：拉取 → upsert 落库 → 账号状态记录
# main.py 的绑定/刷新端点与 scheduler 的轮询循环共用这一份实现。
# 设计约束：网络 I/O 不占着数据库会话（先拉完再开短会话写）；
# 单平台失败不影响其他平台；upsert 按 (user_id, platform, external_key) 幂等。
from datetime import datetime
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import PlatformAccount, SyncedAssignment
from .platforms import AuthError, PlatformError, sync_platform

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

    if not error and complete and account.platform == "chaoxing":
        seen = {i["key"][:200] for i in items}
        for row in existing:
            if row.external_key not in seen:
                db.delete(row)

    account.status = status_for(error)
    account.last_error = error[:200] if error else None
    account.last_sync_at = datetime.now(_TZ_BJ).replace(tzinfo=None)
