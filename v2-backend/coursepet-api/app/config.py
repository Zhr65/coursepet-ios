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
