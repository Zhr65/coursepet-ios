# MARK: - 邀请码：生成 与 原子消费
# 与 FastAPI 解耦（只依赖 sqlalchemy + models），好处是能脱离整个 web 栈单独测试：
#   python -m pytest 或直接起个 SQLite 把 consume_invite 跑一遍。
import secrets
from datetime import datetime

from sqlalchemy import or_, update
from sqlalchemy.orm import Session

from .models import InviteCode

# 去掉 0/O/1/I/L 等易混字符，方便口头念、手抄、截图传递
_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def new_invite_code() -> str:
    """生成一个 8 位易读邀请码"""
    return "".join(secrets.choice(_ALPHABET) for _ in range(8))


def consume_invite(db: Session, code: str) -> bool:
    """原子消费一个邀请码：校验「未吊销 / 未过期 / 未用尽」并 used_count+1。

    关键点：用一条 UPDATE ... WHERE 完成「检查 + 占用」，而不是先 SELECT 再 UPDATE。
    后者在并发下会让「一码一人」的邀请码被两个注册请求同时通过（TOCTOU 竞态）；
    前者由数据库行锁保证只有一个 UPDATE 会 rowcount==1。

    调用方负责 commit —— 与建用户同一事务，建号失败时消费一起回滚，码不会被白白烧掉。"""
    code = (code or "").strip().upper()
    if not code:
        return False
    res = db.execute(
        update(InviteCode)
        .where(
            InviteCode.code == code,
            InviteCode.disabled.is_(False),
            InviteCode.used_count < InviteCode.max_uses,
            or_(InviteCode.expires_at.is_(None),
                InviteCode.expires_at > datetime.utcnow()),
        )
        .values(used_count=InviteCode.used_count + 1)
    )
    return res.rowcount == 1
