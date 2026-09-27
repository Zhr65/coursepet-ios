# MARK: - 全局配置（pydantic-settings：自动从环境变量 / .env 读取）
# 与 V1 的差异：LLM API Key 从「用户在 App 里填（BYOK）」变为「服务端持有」。
# 这是客户端架构 → 服务端架构的核心变化：密钥不再下发到设备。
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # PostgreSQL 连接串：本机 peer 认证（zhr 系统用户 = 数据库 owner）
    database_url: str = "postgresql+psycopg2://zhr@localhost/coursepet"

    # JWT 签名密钥与有效期（7 天）
    jwt_secret: str = "dev-secret-change-me"
    jwt_expire_minutes: int = 60 * 24 * 7

    # LLM 配置（OpenAI 兼容协议，默认 DeepSeek）
    llm_base_url: str = "https://api.deepseek.com/v1"
    llm_api_key: str = ""
    llm_model: str = "deepseek-chat"

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()
