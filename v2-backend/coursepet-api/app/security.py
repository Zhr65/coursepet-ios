# MARK: - 安全层：密码哈希 + JWT 签发/校验
# 密码：PBKDF2-HMAC-SHA256（标准库实现，10 万次迭代 + 随机盐），不存明文。
# JWT：HS256 签名，payload 只放 user_id 与过期时间——无状态鉴权，
#      服务端不用存 session 表，这就是"无状态 Token"相对 Session 的取舍。
import base64
import hashlib
import hmac
import os
import time

import jwt
from cryptography.fernet import Fernet
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from .config import settings
from .database import get_db
from .models import User

_ITERATIONS = 100_000

# ── 密码哈希 ──────────────────────────────────────────
def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _ITERATIONS)
    return f"pbkdf2${_ITERATIONS}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _, iterations, salt_hex, digest_hex = stored.split("$")
        digest = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), bytes.fromhex(salt_hex), int(iterations)
        )
        return hmac.compare_digest(digest.hex(), digest_hex)  # 恒定时间比较，防时序攻击
    except (ValueError, TypeError):
        return False


# ── 平台账号密码加密（作业同步）────────────────────────
# Fernet 对称加密：密钥由 jwt_secret 派生（sha256 → urlsafe base64）。
# 学习通/智慧树密码必须可逆（轮询时要拿明文登录），不能哈希；
# 加密落库保证拖库场景下凭据不直接泄露。
def derive_platform_key() -> bytes:
    digest = hashlib.sha256(("platform|" + settings.jwt_secret).encode()).digest()
    return base64.urlsafe_b64encode(digest)


def encrypt_platform_password(password: str) -> str:
    return Fernet(derive_platform_key()).encrypt(password.encode()).decode()


def decrypt_platform_password(token: str) -> str:
    return Fernet(derive_platform_key()).decrypt(token.encode()).decode()


# ── JWT ───────────────────────────────────────────────
def create_token(user_id: int) -> str:
    payload = {
        "sub": str(user_id),
        "exp": int(time.time()) + settings.jwt_expire_minutes * 60,
        "iat": int(time.time()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm="HS256")


# FastAPI 的 Bearer 提取器：Authorization: Bearer <token>
_bearer = HTTPBearer(auto_error=False)


def get_current_user(
    cred: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: Session = Depends(get_db),
) -> User:
    """路由依赖：从请求头解出 token → 验签 → 查库返回当前用户（失败一律 401）"""
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="请先登录"
    )
    if cred is None:
        raise unauthorized
    try:
        payload = jwt.decode(cred.credentials, settings.jwt_secret, algorithms=["HS256"])
        user_id = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise unauthorized
    user = db.get(User, user_id)
    if user is None:
        raise unauthorized
    return user
