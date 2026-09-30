# MARK: - Agent 引擎（ReAct 循环核心，翻译自 AgentEngine.swift）
# 一次完整交互的流程：
#   用户输入 → [循环开始] → 调 LLM → 模型返回 tool_calls？
#     ├─ 是：逐个在服务端执行工具 → 结果以 role:tool 回填 → 回到循环开头（最多 MAX_ROUNDS 轮）
#     └─ 否：模型给出最终自然语言回答 → 展示 → 结束
# 关键设计（与 V1 一致）：
#   1. 终止条件：MAX_ROUNDS 上限防死循环；工具异常不抛出而是作为结果回填，让模型"自愈"。
#   2. 历史管理：system 恒驻 + 最近 KEEP_ROUNDS 条消息（控制 token 成本）。
#   3. 与 V1 的差异：
#      - 对话历史写穿 PostgreSQL（ConversationMessage 表）——服务重启、换设备登录都能续聊
#        （TODO V2.1 已完成）；每次请求从库里加载最近消息，进程内存不再作为存储。
#      - 主流程重构为 async 生成器 stream()：每产生一条展示消息立即吐出（SSE 流式用）；
#        send() 收集全部消息返回（REST /agent/chat 与评测用，行为与旧版完全一致）。
#      - 对话收尾后异步提取"长期记忆"（交互原则 6），失败静默，不阻塞主链路。
import asyncio
import json
import time
from dataclasses import dataclass, field

import httpx
from sqlalchemy import delete, select

from ..config import settings
from ..database import SessionLocal
from ..models import AgentTask, ConversationMessage, Memory, User
from .embeddings import embed
from .prompts import build_system_prompt
from .tools import build_tools, run_tool

MAX_ROUNDS = 5        # 单次提问最多"模型→工具"往返次数，防死循环
KEEP_ROUNDS = 6       # 上下文保留最近 6 轮（12 条消息）
MEMORY_KEEP = 50      # 每用户长期记忆最多保留条数（超出删最旧）
EXTRACT_MIN_CHARS = 8 # 用户消息太短（如"好"/"嗯"）不值得提取记忆


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
    images: list[str] = field(default_factory=list)  # 拍照多模态：user 消息的 base64 JPEG（仅当轮生效，不持久化）


@dataclass
class DisplayMessage:
    """返回给客户端的展示消息（kind = user / assistant / tool_trace / error）"""
    kind: str
    text: str


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
            "vision_unsupported": "这张图片我暂时看不了：当前模型不支持识图。可以换个说法用文字描述，或在端侧模式配一个支持视觉的模型。",
            "network":       "网络出了点问题，请稍后重试。",
            "bad_response":  "大脑返回了奇怪的内容，再问一次试试。",
        }.get(self.kind, "出了点问题，请稍后重试。")


# ── 工具名 → 用户能看懂的过程标签（V1 traceText 的移植）──
_TRACE_TEXT = {
    "get_today_schedule":      "🔍 翻了翻今天的课表",
    "get_next_class":          "🔍 看了看下节课",
    "get_pending_homeworks":   "📝 数了数没做完的作业",
    "add_homework":            "✍️ 帮你记下这条待办",
    "add_parcel_from_sms":     "📦 帮你记下了这个快递",
    "add_ledger_entry":        "💰 帮你记下这笔账",
    "get_month_expense":       "📊 算了算这个月的账",
    "get_step_count":          "👟 看了看今天的步数",
    "get_weather":             "🌤 瞄了眼今天的天气",
    "undo_last_write":         "↩️ 把刚才那条记录撤掉了",
    "add_course_material":     "📚 收进了你的资料库",
    "search_course_materials": "📚 查了查你的课程资料",
    "create_study_plan":       "🗓 帮你排好了复习计划",
    "check_study_plan":        "🗓 对照了复习计划进度",
    "mark_homework_done":      "✅ 把这条作业划掉了",
    "create_task":             "⏰ 定好了定时任务",
    "list_tasks":              "⏰ 查了查定时任务",
    "save_file":               "💾 存进了你的文件柜",
    "read_file":               "📂 翻开了文件看看",
    "list_files":              "🗂 点了点文件柜",
    "browse_url":              "🌐 上网看了看",
    "web_search":              "🔍 上网搜了搜",
    "list_skills":             "📋 看了看技能库",
    "load_skill":              "📖 读了技能说明书",
}


# ── 对话历史持久化（ConversationMessage 表）───────────

def reset_history(user_id: int) -> None:
    """清空指定用户的对话历史（"新对话"按钮）"""
    db = SessionLocal()
    try:
        db.execute(delete(ConversationMessage)
                   .where(ConversationMessage.user_id == user_id))
        db.commit()
    finally:
        db.close()


def _load_history(user_id: int) -> list[Message]:
    """从 PG 加载最近 KEEP_ROUNDS*2 条消息（按时间正序返回）"""
    db = SessionLocal()
    try:
        rows = db.scalars(
            select(ConversationMessage).where(ConversationMessage.user_id == user_id)
            .order_by(ConversationMessage.id.desc()).limit(KEEP_ROUNDS * 2)
        ).all()
    finally:
        db.close()
    msgs = []
    for r in reversed(rows):
        calls: list[ToolCall] = []
        if r.tool_calls_json:
            try:
                for c in json.loads(r.tool_calls_json):
                    calls.append(ToolCall(id=c["id"], function_name=c["name"],
                                          arguments_json=c.get("arguments") or "{}"))
            except (ValueError, KeyError, TypeError):
                calls = []
        msgs.append(Message(role=r.role, content=r.content,
                            tool_calls=calls, tool_call_id=r.tool_call_id))
    return msgs


def _persist_message(db, user_id: int, msg: Message) -> None:
    """一条引擎消息写穿到 PG（失败不抛出：持久化挂了聊天照常）"""
    try:
        db.add(ConversationMessage(
            user_id=user_id, role=msg.role, content=msg.content[:3900],
            tool_calls_json=json.dumps(
                [{"id": c.id, "name": c.function_name, "arguments": c.arguments_json}
                 for c in msg.tool_calls], ensure_ascii=False) if msg.tool_calls else None,
            tool_call_id=msg.tool_call_id,
        ))
        db.commit()
    except Exception:
        db.rollback()


# ── 主流程：流式生成器 + 收集式包装 ───────────────────

async def stream(user: User, text: str,
                 tools_used: list[str] | None = None,
                 stats: dict | None = None,
                 persist: bool = True,
                 images: list[str] | None = None,
                 calendar_context: str | None = None):
    """处理用户一条消息，逐条 yield 展示消息（SSE 逐条推送）。

    tools_used：可选收集器（评测用）——按调用顺序记录本次用到的工具名；
    传 None 时零开销（正常聊天路径不受影响）。
    stats：可选观测收集器（评测/观测用）——记录本次交互的 LLM 耗时与 token 用量：
      llm_ms（LLM 累计耗时）、llm_calls（调用次数）、prompt_tokens / completion_tokens
      （网关返回 usage 才有，没有则缺省）。"""
    text = text.strip()
    if not text and not (images or []):
        return

    # 持久层会话：整轮对话共用，历史写穿 PG
    hist_db = SessionLocal()
    try:
        # 后台任务执行（persist=False，异步定时任务用）不写对话历史、不提取记忆：
        # 定时任务的执行过程不该出现在用户聊天记录里，结果单独走任务结果通道
        def _persist(msg: Message) -> None:
            if persist:
                _persist_message(hist_db, user.id, msg)

        history = _load_history(user.id)
        user_msg = Message(role="user", content=text, images=list(images or []))
        history.append(user_msg)
        _persist(user_msg)
        yield DisplayMessage(kind="user", text=text)

        if not settings.llm_api_key:
            err = EngineError("not_configured")
            _persist(Message(role="assistant", content=err.friendly_text))
            yield DisplayMessage(kind="error", text=err.friendly_text)
            return

        # 工具执行用独立数据库会话：与请求会话解耦，执行完即关
        # 幂等缓存：同一次 stream 内完全相同的调用（写类工具被推理模型重复触发）直接拦截，
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
        last_answer = ""
        usage_sink: list[dict] = []  # 观测：收集每次 LLM 返回的 usage（网关不给就没有）
        while round_no < MAX_ROUNDS:
            round_no += 1
            # 1. 调用 LLM（计时入 stats：评测的延迟观测数据源）
            t0 = time.monotonic()
            try:
                response = await _call_llm(history, user, usage_sink=usage_sink,
                                           calendar_context=calendar_context)
            except EngineError as e:
                _persist(Message(role="assistant", content=e.friendly_text))
                yield DisplayMessage(kind="error", text=e.friendly_text)
                return
            finally:
                if stats is not None:
                    stats["llm_ms"] = stats.get("llm_ms", 0) + int((time.monotonic() - t0) * 1000)
                    stats["llm_calls"] = stats.get("llm_calls", 0) + 1
                    for u in usage_sink:
                        stats["prompt_tokens"] = stats.get("prompt_tokens", 0) + int(u.get("prompt_tokens") or 0)
                        stats["completion_tokens"] = stats.get("completion_tokens", 0) + int(u.get("completion_tokens") or 0)
                    usage_sink.clear()

            # 2. 模型决定调用工具 → 服务端执行 → 回填 → 继续循环（Act + 再 Reason）
            if response.tool_calls:
                history.append(response)
                _persist(response)
                for call in response.tool_calls:
                    if tools_used is not None:
                        tools_used.append(call.function_name)
                    # show_card 不出过程标签：卡片本身就是可视化结果，多一条标签反而吵
                    if call.function_name != "show_card":
                        label = _TRACE_TEXT.get(call.function_name, "🔍 查了一下")
                        yield DisplayMessage(kind="tool_trace", text=label)
                    result = await execute_with_db(call)
                    # 模式 11：show_card 的合法 JSON 结果 → 以 kind="card" 推给客户端渲染；
                    # 回填给模型的换成"已插入"确认，防止它把卡片数据再用文字复述一遍
                    if call.function_name == "show_card" and result.startswith("{"):
                        yield DisplayMessage(kind="card", text=result)
                        try:
                            card = json.loads(result)
                            result = (f"卡片已插入聊天（{card.get('title')}，{len(card.get('items', []))} 条）。"
                                      "文字回答里不要再重复卡片里的数据。")
                        except ValueError:
                            result = "卡片已插入聊天。文字回答里不要再重复卡片里的数据。"
                    tool_msg = Message(role="tool", content=result, tool_call_id=call.id)
                    history.append(tool_msg)
                    _persist(tool_msg)
                continue

            # 3. 无工具调用 → 最终回答，结束循环
            last_answer = response.content or "（我好像走神了，再说一遍？）"
            history.append(Message(role="assistant", content=last_answer))
            _persist(Message(role="assistant", content=last_answer))
            yield DisplayMessage(kind="assistant", text=last_answer)
            break
        else:
            # 超过轮数上限：如实告诉用户（宁可示弱也不编答案）
            last_answer = "这个问题我查了好几轮还没搞定，要不换个问法？"
            _persist(Message(role="assistant", content=last_answer))
            yield DisplayMessage(kind="assistant", text=last_answer)

        # 对话正常收尾 → 后台提取长期记忆（不阻塞本响应；评测账号跳过保确定）
        if persist and user.username != "__eval__" and len(text) >= EXTRACT_MIN_CHARS:
            _spawn_memory_extraction(user.id, text, last_answer)
    finally:
        hist_db.close()


async def send(user: User, text: str,
               tools_used: list[str] | None = None,
               stats: dict | None = None,
               persist: bool = True,
               images: list[str] | None = None,
               calendar_context: str | None = None) -> list[DisplayMessage]:
    """收集式包装：等 stream 全部产出后一次性返回（REST /agent/chat 与评测用）"""
    return [m async for m in stream(user, text, tools_used, stats, persist, images, calendar_context)]


# ── 长期记忆（交互原则 6）─────────────────────────────

# 后台任务强引用（asyncio 只持弱引用，不拿住会被 GC 掉）
_bg_tasks: set[asyncio.Task] = set()


def _select_memories(facts: list[str], query: str, limit: int = 5) -> list[str]:
    """记忆注入选择器：有 query 且记忆多于 limit 时按哈希嵌入余弦相关性取 top-limit，
    否则原样截断（保持 importance/时间序）。两侧向量均已 L2 归一化，点积即余弦。
    哈希嵌入是确定性纯函数，现场重算零迁移；未来换真嵌入模型只需换 embed()。"""
    if not query or len(facts) <= limit:
        return facts[:limit]
    q = embed(query)
    def score(fact: str) -> float:
        v = embed(fact)
        return sum(a * b for a, b in zip(q, v))
    return sorted(facts, key=score, reverse=True)[:limit]


def _spawn_memory_extraction(user_id: int, user_text: str, assistant_text: str) -> None:
    task = asyncio.create_task(_extract_memories(user_id, user_text, assistant_text))
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)


async def _extract_memories(user_id: int, user_text: str, assistant_text: str) -> None:
    """对话后提取值得长期记住的事实 → 去重入库（上限 MEMORY_KEEP 条）

    任何失败（网络/解析/限流）都静默放弃——记忆是锦上添花，绝不能影响聊天。"""
    try:
        raw = await _cheap_llm(
            "从这段对话中提取值得长期记住的关于用户的事实（目标、偏好、习惯、重要事项）,"
            "每条一句话。只输出 JSON 字符串数组，如 [\"正在备考考研数学\"]；"
            "没有值得记的就输出 []，不要输出任何其他内容。",
            f"用户说：{user_text[:400]}\n助手答：{assistant_text[:400]}",
        )
        start, end = raw.find("["), raw.rfind("]")
        if start < 0 or end <= start:
            return
        facts = json.loads(raw[start:end + 1])
        if not isinstance(facts, list):
            return
        db = SessionLocal()
        try:
            existing = set(db.scalars(
                select(Memory.fact).where(Memory.user_id == user_id)).all())
            for f in facts:
                if isinstance(f, str) and (s := f.strip()) and len(s) <= 180 and s not in existing:
                    db.add(Memory(user_id=user_id, fact=s))
            db.commit()
            # 只保留最近 MEMORY_KEEP 条，防无限膨胀
            ids = db.scalars(
                select(Memory.id).where(Memory.user_id == user_id)
                .order_by(Memory.id.desc())).all()
            stale = ids[MEMORY_KEEP:]
            if stale:
                db.execute(delete(Memory).where(Memory.id.in_(stale)))
                db.commit()
        finally:
            db.close()
    except Exception:  # noqa: BLE001 —— 故意宽捕获：记忆提取永远静默
        pass


async def _cheap_llm(system: str, user: str) -> str:
    """辅助任务（记忆提取）的轻量 LLM 调用：不重试，失败即放弃"""
    body = {
        "model": settings.llm_model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.2,
        # 推理模型的思考链也计 token，余量给足防 content 为空
        "max_tokens": 800,
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {settings.llm_api_key}",
    }
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            settings.llm_base_url.rstrip("/") + "/chat/completions",
            json=body, headers=headers,
        )
    if resp.status_code != 200:
        raise EngineError("network")
    return resp.json()["choices"][0]["message"].get("content") or ""


# ── 兴趣动态（Muse 式"越用越懂你"）─────────────────────

_DISCOVER_SYSTEM = (
    "你是校园宠物管家的兴趣分享引擎。根据用户的兴趣记忆挑一个话题，写一条学生爱看的趣味分享"
    "（历史冷知识/科技资讯/学习方法/校园生活等，选用户最可能有兴趣的方向）。"
    "只输出一个 JSON 对象，不要输出任何其他内容："
    '{"topic":"兴趣标签2-6字","title":"一句话标题(20字内)",'
    '"body":"正文80-150字，口语化、有趣，结尾带一个互动小问题"}'
    "。注意：三个字段的值内部禁止出现英文双引号，需要引用语气时用「」；不要输出 markdown 代码块。"
)


async def generate_discover(db, user) -> tuple[str, str, str]:
    """按用户记忆生成一条兴趣动态，返回 (topic, title, body)。

    main.py 的 /agent/discover 路由与 scheduler 每日预生成共用。
    解析失败自动重试一次；仍失败抛 ValueError（调用方决定怎么兜底）。"""
    from ..models import Memory
    facts = db.scalars(
        select(Memory.fact).where(Memory.user_id == user.id)
        .order_by(Memory.id.desc()).limit(30)).all()
    fact_text = "\n".join(f"- {f}" for f in facts) if facts else "（暂无记忆，从大学生普遍兴趣里挑）"
    user_prompt = (
        f"用户兴趣记忆：\n{fact_text}\n\n"
        f"最近已推过的话题（避免重复）：{', '.join(facts[:8]) or '（无）'}")
    last_err: Exception | None = None
    last_raw = ""
    for attempt in range(2):
        extra = "" if attempt == 0 else "\n\n再强调一次：只输出一个合法 JSON 对象，值内不要有英文双引号。"
        raw = await _cheap_llm(_DISCOVER_SYSTEM, user_prompt + extra)
        last_raw = raw
        try:
            start, end = raw.find("{"), raw.rfind("}")
            obj = json.loads(raw[start:end + 1])
            topic, title, body = str(obj["topic"]).strip(), str(obj["title"]).strip(), str(obj["body"]).strip()
            if not (topic and title and body):
                raise ValueError("空字段")
            return topic[:8], title[:30], body[:300]
        except (json.JSONDecodeError, ValueError, KeyError) as e:
            last_err = e
    raise ValueError(f"动态生成失败（{last_err}）；模型原始输出片段：{last_raw[:150]!r}")


# ── LLM 调用（带重试）─────────────────────────────────

async def _call_llm(history: list[Message], user: User,
                    usage_sink: list[dict] | None = None,
                    calendar_context: str | None = None) -> Message:
    """调用 OpenAI 兼容 chat/completions 接口（V1 callLLM 的移植）

    带指数退避重试（最多 3 次）：429/5xx/网络抖动是 LLM 服务的常态，
    首次评测（75 分）暴露了零重试导致偶发失败直接甩给用户的问题。
    401（Key 错）不重试——重试也不会好。
    usage_sink：可选收集器——网关返回 token usage 时追加进来（成本观测；不给则静默）。"""
    # 长期记忆注入：按"最近一条用户消息"的相关性检索 top-5（哈希嵌入余弦），
    # 替代旧的"盲取最新5条"——记忆有 FIFO 上限，盲取会视野截断：存了50条但每次
    # 只看得见5条，与当前话题相关的旧私事（如花生过敏）可能刚好不在其中。
    # 后台任务执行时 query 即任务标题，任务相关记忆必被召回。
    db = SessionLocal()
    try:
        all_mem = db.scalars(
            select(Memory).where(Memory.user_id == user.id)
            .order_by(Memory.importance.desc(), Memory.id.desc())
        ).all()
        query_text = next((m.content for m in reversed(history) if m.role == "user" and m.content), "")
        memories = _select_memories([m.fact for m in all_mem], query_text)
        # 进行中的异步任务：注入 system prompt，让模型知道自己有哪些"定期承诺"，
        # 用户问"你都在帮我做什么"时不用再调 list_tasks 也能答
        tasks = db.scalars(
            select(AgentTask).where(AgentTask.user_id == user.id, AgentTask.status == "active")
            .order_by(AgentTask.next_run_at).limit(10)
        ).all()
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

    payload_messages: list[dict] = [
        {"role": "system",
         "content": build_system_prompt(user, memories=list(memories), tasks=list(tasks),
                                        calendar=calendar_context)}
    ]
    for msg in history:
        # 拍照多模态：带图 user 消息转 OpenAI vision content parts（base64 data URL）
        if msg.role == "user" and msg.images:
            parts: list[dict] = []
            if msg.content:
                parts.append({"type": "text", "text": msg.content})
            for b64 in msg.images:
                raw = b64.split(",")[-1]   # 兼容客户端直接发 data URL 前缀
                parts.append({"type": "image_url",
                              "image_url": {"url": f"data:image/jpeg;base64,{raw}"}})
            m = {"role": "user", "content": parts}
        else:
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

    # 本次请求是否带图：非 200 时用于区分"模型不支持识图"（400 类）与普通网络错误
    has_images = any(m["role"] == "user" and isinstance(m.get("content"), list) for m in payload_messages)
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
            # 400/422 通常是网关/模型拒绝图片输入（不支持 vision）
            raise EngineError("vision_unsupported" if has_images else "network")

        try:
            resp_json = resp.json()
            message = resp_json["choices"][0]["message"]
        except (KeyError, IndexError, ValueError):
            raise EngineError("bad_response")
        # 成本观测：网关带 usage 就收集（OpenAI 兼容字段，agnes 不给则无感知跳过）
        if usage_sink is not None and isinstance(resp_json.get("usage"), dict):
            usage_sink.append(resp_json["usage"])

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
