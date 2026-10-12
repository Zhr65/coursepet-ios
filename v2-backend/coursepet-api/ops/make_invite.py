#!/usr/bin/env python3
"""邀请码工具 —— 生成 / 查看 / 吊销，全程不重启服务。

在服务器上、项目根目录（如 /root/coursepet-api）执行：

    python ops/make_invite.py                    # 生成 1 个：1 人 1 码、7 天有效
    python ops/make_invite.py --uses 3           # 一码可注册 3 人
    python ops/make_invite.py --days 0           # 永不过期
    python ops/make_invite.py --note 老王         # 加备注，便于日后分辨
    python ops/make_invite.py --list             # 列出全部
    python ops/make_invite.py --revoke ABC23XYZ  # 吊销指定码

拿到码后发给朋友，他在 App 登录页切到「注册」、填入邀请码即可。
"""
import argparse
import sys
from datetime import datetime, timedelta

sys.path.insert(0, ".")  # 允许从项目根目录直接 python ops/make_invite.py

from app.database import Base, SessionLocal, engine   # noqa: E402
from app.invites import new_invite_code               # noqa: E402
from app.models import InviteCode                      # noqa: E402


def _state(row: InviteCode) -> str:
    if row.disabled:
        return "已吊销"
    if row.used_count >= row.max_uses:
        return "已用完"
    if row.expires_at and row.expires_at < datetime.utcnow():
        return "已过期"
    return "可用"


def main() -> None:
    ap = argparse.ArgumentParser(description="CoursePet 邀请码工具")
    ap.add_argument("--uses", type=int, default=1, help="最多可注册几人（默认 1）")
    ap.add_argument("--days", type=int, default=7, help="有效天数，0=永不过期（默认 7）")
    ap.add_argument("--note", default="", help="备注，如给谁用")
    ap.add_argument("--list", action="store_true", help="列出全部邀请码")
    ap.add_argument("--revoke", metavar="CODE", help="吊销指定邀请码")
    args = ap.parse_args()

    Base.metadata.create_all(bind=engine)  # 表不存在时补建（幂等）
    db = SessionLocal()
    try:
        if args.list:
            rows = db.query(InviteCode).order_by(InviteCode.id.desc()).all()
            if not rows:
                print("（暂无邀请码）")
                return
            print(f"{'码':<10} {'状态':<6} {'用量':<7} {'到期':<17} 备注")
            for r in rows:
                exp = r.expires_at.strftime("%Y-%m-%d %H:%M") if r.expires_at else "永不"
                print(f"{r.code:<10} {_state(r):<6} "
                      f"{str(r.used_count) + '/' + str(r.max_uses):<7} {exp:<17} {r.note or '-'}")
            return

        if args.revoke:
            code = args.revoke.strip().upper()
            row = db.query(InviteCode).filter(InviteCode.code == code).first()
            if not row:
                print(f"没找到邀请码 {code}")
                sys.exit(1)
            row.disabled = True
            db.commit()
            print(f"已吊销 {code}")
            return

        # 生成：极小概率撞码，重试几次
        code = ""
        for _ in range(6):
            code = new_invite_code()
            if db.query(InviteCode).filter(InviteCode.code == code).first() is None:
                break
        row = InviteCode(
            code=code,
            note=args.note,
            max_uses=max(1, args.uses),
            expires_at=(datetime.utcnow() + timedelta(days=args.days)) if args.days > 0 else None,
        )
        db.add(row)
        db.commit()
        exp = row.expires_at.strftime("%Y-%m-%d %H:%M") if row.expires_at else "永不过期"
        print(f"邀请码：{row.code}")
        print(f"可注册 {row.max_uses} 人 · 到期 {exp}")
    finally:
        db.close()


if __name__ == "__main__":
    main()
