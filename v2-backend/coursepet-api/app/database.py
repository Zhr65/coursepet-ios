# MARK: - 数据库连接（SQLAlchemy）
# engine   = 连接池（整个进程一个）
# SessionLocal = 会话工厂，每个请求建一个会话，用完关闭
# get_db   = FastAPI 依赖注入：路由函数声明 db: Session = Depends(get_db) 即可拿到会话
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    """所有 ORM 模型的基类（SQLAlchemy 2.0 风格）"""


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
