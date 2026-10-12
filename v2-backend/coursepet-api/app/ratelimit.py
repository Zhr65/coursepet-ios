# MARK: - 轻量限流（单进程内存滑窗）
# 为什么是内存而不是 Redis：本服务本来就是单进程 asyncio（scheduler 也是进程内循环），
# 引入 Redis 只为限流属于过度设计。等真要多进程/多实例时再换 Redis 或网关限流。
#
# 两层闸门：单用户每分钟 _PER_USER 次 + 全局每分钟 _GLOBAL_MAX 次。
# 目的：LLM Key 在服务端持有，必须防止单账号刷穿额度、以及被注册机器人批量白嫖。
import time
from collections import defaultdict, deque

from fastapi import HTTPException

_WINDOW = 60.0        # 滑窗长度（秒）
_PER_USER = 20        # 单用户每分钟上限
_GLOBAL_MAX = 120     # 全局每分钟上限

_global: deque[float] = deque()
_per_user: dict[int, deque[float]] = defaultdict(deque)


def check_rate_limit(user_id: int) -> None:
    """超过阈值抛 429；否则记账一次。在对话类路由入口调用。"""
    now = time.monotonic()

    while _global and now - _global[0] > _WINDOW:
        _global.popleft()
    bucket = _per_user[user_id]
    while bucket and now - bucket[0] > _WINDOW:
        bucket.popleft()

    if len(_global) >= _GLOBAL_MAX or len(bucket) >= _PER_USER:
        raise HTTPException(status_code=429, detail="调用太频繁，休息几秒再试。")

    _global.append(now)
    bucket.append(now)
