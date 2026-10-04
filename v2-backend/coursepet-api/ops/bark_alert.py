#!/usr/bin/env python3
"""CoursePet 服务器健康告警（Bark）：health_monitor.sh 专用。

用法：bark_alert.py down|recovered
  down      —— 自动重启后仍未恢复：给所有配了 Bark Key 的用户推告警，
               按小时桶防重（同小时最多一条，复用 push_logs 表的 push_once）
  recovered —— 服务恢复：仅当最近 3 小时内真的给该用户告警过才补发，无事不打扰
"""
import asyncio
import sys
from datetime import datetime, timedelta

# 与服务器部署目录一致（app 包的父目录），使脚本可在任意 cwd 下运行
sys.path.insert(0, "/root/coursepet-api")

from sqlalchemy import select  # noqa: E402

from app.database import SessionLocal  # noqa: E402
from app.models import PushLog, User  # noqa: E402
from app.notifications import push_bark, push_once  # noqa: E402


def bark_users():
    """[(user_id, bark_key)]，只取配了 Key 的用户；没配的自然收不到，不算失败。"""
    with SessionLocal() as db:
        return db.execute(
            select(User.id, User.bark_key).where(User.bark_key != "")
        ).all()


async def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "down":
        bucket = "down-" + datetime.now().strftime("%Y%m%d%H")
        for user_id, _key in bark_users():
            await push_once(
                user_id, "server_health", bucket,
                "CoursePet 服务器告警",
                "服务异常已自动重启，但仍未恢复，请尽快登录服务器排查",
                group="服务器监控",
            )
    elif mode == "recovered":
        recent_cut = datetime.now() - timedelta(hours=3)
        for user_id, key in bark_users():
            with SessionLocal() as db:
                alerted = db.scalar(select(PushLog).where(
                    PushLog.user_id == user_id,
                    PushLog.kind == "server_health",
                    PushLog.dedup_key.like("down-%"),
                    PushLog.created_at >= recent_cut))
            if alerted is not None:
                await push_bark(key, "CoursePet 服务器恢复",
                                "服务已恢复正常，本次告警结束", group="服务器监控")
    else:
        print("usage: bark_alert.py down|recovered", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    asyncio.run(main())
