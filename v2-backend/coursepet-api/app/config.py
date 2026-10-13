# MARK: - 全局配置（pydantic-settings：自动从环境变量 / .env 读取）
# 与 V1 的差异：LLM API Key 从「用户在 App 里填（BYOK）」变为「服务端持有」。
# 这是客户端架构 → 服务端架构的核心变化：密钥不再下发到设备。
from pydantic import field_validator
from pydantic_settings import BaseSettings

# 已知的弱密钥 / 占位符：命中即拒绝启动，避免"默认密钥裸奔"
_WEAK_SECRETS = {"", "dev-secret-change-me", "change-me-to-a-long-random-string"}


class Settings(BaseSettings):
    # PostgreSQL 连接串：本机 peer 认证（zhr 系统用户 = 数据库 owner）
    database_url: str = "postgresql+psycopg2://zhr@localhost/coursepet"

    # JWT 签名密钥与有效期（7 天）
    # 无默认值：必须由 .env / 环境变量提供；缺失或过弱则在 import 时抛错，服务拒绝启动。
    # 注意它同时派生平台账号密码的 Fernet 密钥（security.derive_platform_key），
    # 一旦使用公开默认值，等于 JWT 可被伪造 + 学习通/智慧树凭据可被解密。
    jwt_secret: str = ""
    jwt_expire_minutes: int = 60 * 24 * 7

    # 注册开关：默认关闭（安全默认）。需要开通新账号时在 .env 里临时置 true，注册完改回。
    register_open: bool = False

    # 管理员种子：首次启动若该用户名不存在则自动创建（is_admin=True），
    # 临时密码打印到日志（首次启动后必须立刻保存，否则唯一一次机会）。
    # 留空 = 不自动种管理员，需要你手动用 SQL/脚本创建第一个管理员。
    admin_username: str = ""

    @field_validator("jwt_secret")
    @classmethod
    def _require_strong_secret(cls, v: str) -> str:
        if v.strip() in _WEAK_SECRETS or len(v) < 32:
            raise ValueError(
                "JWT_SECRET 未设置或过弱（需 >=32 位随机串）。生成方法：\n"
                "  python -c \"import secrets;print(secrets.token_urlsafe(48))\"\n"
                "然后写入 v2-backend/coursepet-api/.env 的 JWT_SECRET= 一行。"
            )
        return v

    # LLM 配置（OpenAI 兼容协议，默认 DeepSeek）
    llm_base_url: str = "https://api.deepseek.com/v1"
    llm_api_key: str = ""
    llm_model: str = "deepseek-chat"
    # 图像理解模型（场景路由）：带图消息（拍照识别）自动切此模型；空=跟随 llm_model。
    # 需与主模型同一家服务商（共用 llm_base_url 与 llm_api_key），如 glm-5.3-flash
    llm_vision_model: str = ""

    # 用户文件柜根目录（Muse 式文件系统）：每个用户一个子目录 {files_root}/{user_id}
    # 部署机需一次性初始化：sudo mkdir -p /data/users && sudo chown zhr /data/users
    files_root: str = "/data/users"

    # 可选：web_search 联网搜索（tavily.com 免费申请，.env 配 TAVILY_API_KEY）
    tavily_api_key: str = ""

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


settings = Settings()
