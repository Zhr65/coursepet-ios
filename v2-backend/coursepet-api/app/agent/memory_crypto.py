# MARK: - 长期记忆的 Fernet 加解密（MemoryEntry.content 密文落库）
# key = sha256("memory|" + jwt_secret + "|" + user_id)，每用户独立派生；
# DB 泄露时记忆内容不随明文暴露。注意：jwt_secret 变更会让旧密文全部解不开，
# decrypt 解不开时返回空串（该条记忆按不存在处理，绝不影响聊天主链路）。
import base64
import hashlib

from cryptography.fernet import Fernet, InvalidToken

from ..config import settings


def _fernet(user_id: int) -> Fernet:
    key = hashlib.sha256(f"memory|{settings.jwt_secret}|{user_id}".encode()).digest()
    return Fernet(base64.urlsafe_b64encode(key))


def encrypt_memory(user_id: int, text: str) -> str:
    return _fernet(user_id).encrypt(text.encode("utf-8")).decode("ascii")


def decrypt_memory(user_id: int, token: str) -> str:
    try:
        return _fernet(user_id).decrypt(token.encode("ascii")).decode("utf-8")
    except (InvalidToken, ValueError):
        return ""
