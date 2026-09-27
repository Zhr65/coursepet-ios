# MARK: - Agent 引擎（ReAct 循环核心，翻译自 AgentEngine.swift）
# 一次完整交互的流程：
#   用户输入 → [循环开始] → 调 LLM → 模型返回 tool_calls？
#     ├─ 是：逐个在服务端执行工具 → 结果以 role:tool 回填 → 回到循环开头（最多 MAX_ROUNDS 轮）
#     └─ 否：模型给出最终自然语言回答 → 展示 → 结束
# 关键设计（与 V1 一致）：
#   1. 终止条件：MAX_ROUNDS 上限防死循环；工具异常不抛出而是作为结果回填，让模型"自愈"。
#   2. 历史管理：system 恒驻 + 最近 KEEP_ROUNDS 轮对话（控制 token 成本）。
#   3. 与 V1 的差异：对话历史存服务端内存（按 user_id 隔离）——同一账号换设备也能续聊。
#      TODO(V2.1)：落 PostgreSQL 持久化。
import asyncio
import time
from dataclasses import dataclass, field

import httpx

from ..config import settings
from ..database import SessionLocal
from ..models import User
from .prompts import build_system_prompt
from .tools import build_tools, run_tool

MAX_ROUNDS = 5   # 单次提问最多"模型→工具"往返次数，防死循环
KEEP_ROUNDS = 6  # 长期历史保留最近 6 轮（12 条消息）


@dataclass
class ToolCall:
    id: str            # 调用唯一 id，回填结果时必须带上
    function_name: str
    arguments_json: str


@dataclass
class Message:
    role: str                                # system / user / assistant / tool
    content: str
    tool_calls: list[ToolCall] = field(default_factory=list)
    tool_call_id: str | None = None          # tool 消息必须携带，关联回哪次调用


@dataclass
class DisplayMessage:
    """返回给客户端的展示消息（kind = user / assistant / tool_trace / error）"""
    kind: str
    text: str


# ── 对话历史（进程内存，按用户隔离）──────────────────
_histories: dict[int, list[Message]] = {}


def reset_history(user_id: int) -> None:
    """清空指定用户的对话历史（"新对话"按钮）"""
    _histories.pop(user_id, None)


class EngineError(Exception):
    """引擎层错误 → 转 friendly 文案给用户"""

    def __init__(self, kind: str):
        self.kind = kind
        super().__init__(kind)

    @property
    def friendly_text(self) -> str:
        return {
            "not_configured": "我还没接到大脑呢！服务器还没配置 LLM API Key。",
            "bad_api_key":   "API Key 好像不对（服务端返回 401），请检查服务器配置。",
            "rate_limited":  "调用太频繁啦，休息几秒再试。",
            "network":       "网络出了点问题，请稍后重试。",
            "bad_response":  "大脑返回了奇怪的内容，再问一次试试。",
        }.get(self.kind, "出了点问题，请稍后重试。")


# ── 工具名 → 用户能看懂的过程标签（V1 traceText 的移植）──
_TRACE_TEXT = {
    "get_today_schedule":    "🔍 翻了翻今天的课表",
    "get_next_class":        "🔍 看了看下节课",
    "get_pending_homeworks": "📝 数了数没做完的作业",
    "add_homework":          "✍️ 帮你记下这条待办",
    "add_parcel_from_sms":   "📦 帮你记下了这个快递",
    "add_ledger_entry":      "💰 帮你记下这笔账",
    "get_month_expense":     "📊 算了算这个月的账",
    "get_step_count":        "👟 看了看今天的步数",
    "get_weather":           "🌤 瞄了眼今天的天气",
}


async def send(user: User, text: str,
               tools_used: list[str] | None = None) -> list[DisplayMessage]:
    """处理用户一条消息，返回完整的过程展示（过程标签 + 最终回答）

    tools_used：可选收集器（评测用）——按调用顺序记录本次用到的工具名；
    传 None 时零开销（正常聊天路径不受影响）。"""
    text = text.strip()
    if not text:
        return []

    history = _histories.setdefault(user.id, [])
    history.append(Message(role="user", content=text))
    display: list[DisplayMessage] = [DisplayMessage(kind="user", text=text)]

    if not settings.llm_api_key:
        err = EngineError("not_configured")
        _append_error(history, display, err.friendly_text)
        return display

    # 工具执行用独立数据库会话：与请求会话解耦，执行完即关
    # 幂等缓存：同一次 send 内完全相同的调用（写类工具被推理模型重复触发）直接拦截，
    # 防止"记一笔变两笔"；读类工具命中缓存也省一次查库
    tool_cache: dict[tuple[str, str], str] = {}

    async def execute_with_db(call: ToolCall) -> str:
        cache_key = (call.function_name, call.arguments_json.strip())
        if cache_key in tool_cache:
            return "（重复调用已拦截——这条刚刚已经处理过了，请直接回答用户。）"
        db = SessionLocal()
        try:
            # 按名字找回对应工具并执行
            for t in build_tools():
                if t.name == call.function_name:
                    result = await run_tool(t, call.arguments_json, user, db)
                    tool_cache[cache_key] = result
                    return result
            return f"未知工具：{call.function_name}"
        finally:
            db.close()

    round_no = 0
    while round_no < MAX_ROUNDS:
        round_no += 1
        # 1. 调用 LLM
        try:
            response = await _call_llm(history, user)
        except EngineError as e:
            _append_error(history, display, e.friendly_text)
            return display

        # 2. 模型决定调用工具 → 服务端执行 → 回填 → 继续循环（Act + 再 Reason）
        if response.tool_calls:
            history.append(response)
            for call in response.tool_calls:
                if tools_used is not None:
                    tools_used.append(call.function_name)
                label = _TRACE_TEXT.get(call.function_name, "🔍 查了一下")
                display.append(DisplayMessage(kind="tool_trace", text=label))
                result = await execute_with_db(call)
                history.append(Message(role="tool", content=result, tool_call_id=call.id))
            continue

        # 3. 无工具调用 → 最终回答，结束循环
        answer = response.content or "（我好像走神了，再说一遍？）"
        history.append(Message(role="assistant", content=answer))
        display.append(DisplayMessage(kind="assistant", text=answer))
        _trim(history)
        return display

    # 超过轮数上限：如实告诉用户（宁可示弱也不编答案）
    text_out = "这个问题我查了好几轮还没搞定，要不换个问法？"
    _append_error(history, display, text_out, is_error=False)
    return display


# ── 内部实现 ──────────────────────────────────────────

def _append_error(history: list[Message], display: list[DisplayMessage],
                  text: str, is_error: bool = True) -> None:
    history.append(Message(role="assistant", content=text))
    display.append(DisplayMessage(kind="error" if is_error else "assistant", text=text))


def _trim(history: list[Message]) -> None:
    """历史裁剪：只保留最近 KEEP_ROUNDS 轮（一条 user + 一条 assistant 算一轮）"""
    keep = KEEP_ROUNDS * 2
    if len(history) > keep:
        del history[:-keep]


async def _call_llm(history: list[Message], user: User) -> Message:
    """调用 OpenAI 兼容 chat/completions 接口（V1 callLLM 的移植）

    带指数退避重试（最多 3 次）：429/5xx/网络抖动是 LLM 服务的常态，
    首次评测（75 分）暴露了零重试导致偶发失败直接甩给用户的问题。
    401（Key 错）不重试——重试也不会好。"""
    payload_messages: list[dict] = [
        {"role": "system", "content": build_system_prompt(user)}
    ]
    for msg in history:
        m: dict = {"role": msg.role, "content": msg.content}
        if msg.tool_calls:
            m["tool_calls"] = [
                {
                    "id": c.id,
                    "type": "function",
                    "function": {"name": c.function_name, "arguments": c.arguments_json},
                }
                for c in msg.tool_calls
            ]
        if msg.tool_call_id:
            m["tool_call_id"] = msg.tool_call_id
        payload_messages.append(m)

    # 工具 schema 列表（每轮实时构建，无需缓存）
    db = SessionLocal()
    try:
        tools_payload = [
            {
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters,
                },
            }
            for t in build_tools()
        ]
    finally:
        db.close()

    body = {
        "model": settings.llm_model,
        "messages": payload_messages,
        "tools": tools_payload,
        "temperature": 0.6,
        # agnes-2.5-flash 是推理模型：思考链(reasoning)也计 token，给足余量防止答案被截断
        "max_tokens": 1600,
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {settings.llm_api_key}",
    }

    last_error: EngineError | None = None
    for attempt in range(3):
        if attempt:
            await asyncio.sleep(1.5 * attempt)   # 线性退避：1.5s / 3s
        try:
            async with httpx.AsyncClient(timeout=60) as client:
                resp = await client.post(
                    settings.llm_base_url.rstrip("/") + "/chat/completions",
                    json=body, headers=headers,
                )
        except httpx.HTTPError:
            last_error = EngineError("network")
            continue

        if resp.status_code == 401:
            raise EngineError("bad_api_key")     # Key 错误不重试
        if resp.status_code == 429 or resp.status_code >= 500:
            last_error = EngineError("rate_limited" if resp.status_code == 429 else "network")
            continue                             # 限流/服务端错误：退避后重试
        if resp.status_code != 200:
            raise EngineError("network")

        try:
            message = resp.json()["choices"][0]["message"]
        except (KeyError, IndexError, ValueError):
            raise EngineError("bad_response")

        content = message.get("content") or ""
        calls: list[ToolCall] = []
        for raw in message.get("tool_calls") or []:
            try:
                calls.append(ToolCall(
                    id=raw["id"],
                    function_name=raw["function"]["name"],
                    arguments_json=raw["function"].get("arguments") or "{}",
                ))
            except (KeyError, TypeError):
                continue
        return Message(role="assistant", content=content, tool_calls=calls)

    raise last_error or EngineError("network")
