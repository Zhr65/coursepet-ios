# MARK: - 安全层：密码哈希 + JWT 签发/校验
# 密码：PBKDF2-HMAC-SHA256（标准库实现，10 万次迭代 + 随机盐），不存明文。
# JWT：HS256 签名，payload 只放 user_id 与过期时间——无状态鉴权，
#      服务端不用存 session 表，这就是"无状态 Token"相对 Session 的取舍。
import base64
import hashlib
import hmac
import os
import time
from datetime import datetime, timedelta

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


# Refresh Token：30 天有效、随机字符串（不是 JWT），存数据库便于主动吊销
REFRESH_EXPIRE_DAYS = 30


def create_refresh_token() -> tuple[str, datetime]:
    """生成随机 refresh_token；返回 (token, 过期时刻)"""
    token = os.urandom(32).hex()
    expire = datetime.utcnow() + timedelta(days=REFRESH_EXPIRE_DAYS)
    return token, expire


# ── Sign in with Apple ────────────────────────────────
# Apple 的 identity_token 是 JWT，iss="https://appleid.apple.com"
# 签名用 RS256，公钥在 https://appleid.apple.com/auth/keys（JWKS）
# 首次请求时拉一次，缓存到模块级变量（苹果公钥很少变）

_apple_keys_cache: dict | None = None

# Apple 的 Team ID（从 Certificates, Identifiers & Profiles 页面顶部拿，
# 用于校验 identity_token 的 audience 是否是我们自己的 App；
# 暂时允许所有 audience，后续收紧时取消注释下面两行）
# _APPLE_TEAM_ID = "你的 Team ID"
# _APPLE_BUNDLE_ID = "com.coursepet.app"


def _fetch_apple_keys() -> dict:
    """拉取苹果 JWKS 公钥集合（缓存 1 小时）"""
    import httpx
    global _apple_keys_cache
    if _apple_keys_cache is not None:
        return _apple_keys_cache
    resp = httpx.get("https://appleid.apple.com/auth/keys", timeout=10)
    resp.raise_for_status()
    _apple_keys_cache = resp.json()
    # 缓存到期：苹果 header 里有 max-age，这里硬编码 3600 秒
    import threading
    def _clear():
        global _apple_keys_cache
        _apple_keys_cache = None
    threading.Timer(3600, _clear).start()
    return _apple_keys_cache


def verify_apple_identity_token(identity_token: str) -> dict:
    """验证 identity_token 签名 + 过期时间 + iss，返回 payload

    payload 里有：sub（Apple 用户唯一 ID，最重要）、email、aud、exp 等。
    抛 ValueError = 验证失败，调用方应该返回 401。"""
    from jwt import PyJWKClient

    keys = _fetch_apple_keys()
    jwks_client = PyJWKClient("https://appleid.apple.com/auth/keys")
    signing_key = jwks_client.get_signing_key_from_jwt(identity_token)

    payload = jwt.decode(
        identity_token,
        signing_key.key,
        algorithms=["RS256"],
        issuer="https://appleid.apple.com",
        options={"verify_exp": True},
    )
    return payload


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
