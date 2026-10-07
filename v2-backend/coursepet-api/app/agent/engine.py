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
from ..models import AgentTask, ConversationMessage, MemoryEntry, User
from .embeddings import embed
from .memory_crypto import decrypt_memory, encrypt_memory
from .prompts import build_system_prompt
from .tools import build_tools, run_tool

MAX_ROUNDS = 5        # 单次提问最多"模型→工具"往返次数，防死循环
KEEP_ROUNDS = 6       # 上下文保留最近 6 轮（12 条消息）
MEMORY_KEEP = 300     # 每用户长期记忆活跃条数上限（超出淘汰低重要+最旧）
EXTRACT_MIN_CHARS = 8 # 用户消息太短（如"好"/"嗯"）不值得提取记忆
MEMORY_KINDS = ("fact", "preference", "person", "promise")  # 记忆四类白名单
# 写操作确认卡工具（服务器意图卡）：返回确认 JSON 等用户点头，客户端本地执行，不落服务器库
CONFIRMATION_TOOLS = frozenset({"add_homework", "add_ledger_entry"})
_memory_rounds: dict[int, int] = {}  # 旧客户端记忆提取轮次计数（新客户端自带 turns_since_extract）


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
# add_homework / add_ledger_entry 走确认卡不出过程标签，故不在表内
_TRACE_TEXT = {
    "get_today_schedule":      "🔍 翻了翻今天的课表",
    "get_next_class":          "🔍 看了看下节课",
    "get_pending_homeworks":   "📝 数了数没做完的作业",
    "add_parcel_from_sms":     "📦 帮你记下了这个快递",
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
    "create_pet_task":         "💌 建好了主动发消息的任务",
    "list_pet_tasks":          "💌 看了看宠物任务",
    "remove_pet_task":         "💌 停掉了一个宠物任务",
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
                 calendar_context: str | None = None,
                 turns_since_extract: int = 0):
    """处理用户一条消息，逐条 yield 展示消息（SSE 逐条推送）。

    tools_used：可选收集器（评测用）——按调用顺序记录本次用到的工具名；
    传 None 时零开销（正常聊天路径不受影响）。
    stats：可选观测收集器（评测/观测用）——记录本次交互的 LLM 耗时与 token 用量：
      llm_ms（LLM 累计耗时）、llm_calls（调用次数）、prompt_tokens / completion_tokens
      （网关返回 usage 才有，没有则缺省）。
    turns_since_extract：客户端带来的"距上次记忆提炼过了几轮"（新客户端每轮都带，
    ≥3 触发提炼；0 = 旧客户端没带，退回服务器内存计数）。"""
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
                    # show_card / 确认卡工具不出过程标签：卡片本身就是可视化结果，多一条标签反而吵
                    if call.function_name != "show_card" and call.function_name not in CONFIRMATION_TOOLS:
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
                    # 写操作确认卡（服务器意图卡）：工具返回确认 JSON → kind="confirmation" 推给客户端，
                    # 用户点头后由客户端写入手机本地库（数据同源：写操作不落服务器库）；
                    # 校验失败时工具返回的是普通错误文本，走常规回填让模型自愈
                    if call.function_name in CONFIRMATION_TOOLS and '"confirmation"' in result:
                        yield DisplayMessage(kind="confirmation", text=result)
                        try:
                            conf = json.loads(result)["confirmation"]
                            result = (f"确认卡已展示给用户（{conf.get('title')}）。用户点卡片上的「记上」后会自动执行，"
                                      "不要再用文字复述操作内容，一句话请TA点一下卡片就行。")
                        except (ValueError, KeyError):
                            result = "确认卡已展示给用户。一句话请TA点一下卡片上的「记上」就行。"
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
        # 提取降频：每轮都调小 LLM 是免费档限流的主要放大器之一，每 3 轮提一次。
        # 新客户端每轮自带 turns_since_extract（1/2/3…，触发后归零），服务器不再自算；
        # 旧客户端不带（=0），退回内存计数（重启归零无碍——少提一轮不丢关键事实）
        if persist and user.username != "__eval__" and len(text) >= EXTRACT_MIN_CHARS:
            if turns_since_extract >= 3:
                _spawn_memory_extraction(user.id, text, last_answer)
            elif turns_since_extract == 0:
                _memory_rounds[user.id] = _memory_rounds.get(user.id, 0) + 1
                if _memory_rounds[user.id] % 3 == 1:
                    _spawn_memory_extraction(user.id, text, last_answer)
    finally:
        hist_db.close()


async def send(user: User, text: str,
               tools_used: list[str] | None = None,
               stats: dict | None = None,
               persist: bool = True,
               images: list[str] | None = None,
               calendar_context: str | None = None,
               turns_since_extract: int = 0) -> list[DisplayMessage]:
    """收集式包装：等 stream 全部产出后一次性返回（REST /agent/chat 与评测用）"""
    return [m async for m in stream(user, text, tools_used, stats, persist, images,
                                    calendar_context, turns_since_extract)]


# ── 长期记忆（交互原则 6）─────────────────────────────

# 后台任务强引用（asyncio 只持弱引用，不拿住会被 GC 掉）
_bg_tasks: set[asyncio.Task] = set()


def _select_memories(entries: list[tuple[str, str]], query: str,
                     limit: int = 8) -> list[tuple[str, str]]:
    """记忆注入选择器：[(kind, content)] → 按 query 相关性取 top-limit。
    有 query 且记忆多于 limit 时按哈希嵌入余弦相关性取，否则保序截断
    （上游已按 importance/时间排序）。两侧向量均已 L2 归一化，点积即余弦。
    哈希嵌入是确定性纯函数，现场重算零迁移；未来换真嵌入模型只需换 embed()。"""
    if not query or len(entries) <= limit:
        return entries[:limit]
    q = embed(query)
    def score(entry: tuple[str, str]) -> float:
        v = embed(entry[1])
        return sum(a * b for a, b in zip(q, v))
    return sorted(entries, key=score, reverse=True)[:limit]


def _spawn_memory_extraction(user_id: int, user_text: str, assistant_text: str) -> None:
    task = asyncio.create_task(_extract_memories(user_id, user_text, assistant_text))
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)


_MEMORY_DIFF_SYSTEM = (
    "你维护一份校园助手的长期记忆库，记录主人的长期有用信息，分四类："
    "fact 事实（目标/计划/专业/习惯）、preference 偏好（喜欢/讨厌什么）、"
    "person 重要的人（室友/家人/朋友相关）、promise 承诺（主人答应过或要求你记住的事）。"
    "对照已知记忆检查本轮对话，输出一个 JSON 对象（不要输出任何其他内容）：\n"
    '{"add":[{"kind":"fact","content":"一句话新记忆"}],'
    '"update":[{"old":"要修改的旧记忆原文","kind":"fact","content":"修改后的一句话"}],'
    '"forget":["要删除的旧记忆原文"]}\n'
    "规则：闲聊客套不记；add 最多 2 条；信息没变化就输出 {\"add\":[],\"update\":[],\"forget\":[]}；"
    "禁止编造；content 一句话不超过 60 字，值内禁止英文双引号；"
    "已过时/已完成的旧记忆放进 forget（比如已考完的试、已放弃的计划）。"
)


async def _extract_memories(user_id: int, user_text: str, assistant_text: str) -> None:
    """对话后提炼 memory_diff（add/update/forget）→ 加密落库（活跃上限 MEMORY_KEEP 条）

    update = 新增一条 + 旧条 superseded_by 指向新条（软删）；forget = 旧条 superseded_by=-1。
    任何失败（网络/解析/限流）都静默放弃——记忆是锦上添花，绝不能影响聊天。"""
    try:
        # 现有活跃记忆喂给模型对照（最近 30 条够了；密文先解密）
        db = SessionLocal()
        try:
            rows = db.scalars(
                select(MemoryEntry)
                .where(MemoryEntry.user_id == user_id,
                       MemoryEntry.superseded_by.is_(None))
                .order_by(MemoryEntry.importance.desc(), MemoryEntry.id.desc())
                .limit(30)).all()
            existing = [(r.id, r.kind, decrypt_memory(user_id, r.content)) for r in rows]
        finally:
            db.close()
        existing = [(i, k, t) for i, k, t in existing if t]
        existing_text = "\n".join(f"[{i}]({k}) {t}" for i, k, _ in existing) if existing else "（还没有任何记忆）"

        raw = await _cheap_llm(
            _MEMORY_DIFF_SYSTEM,
            f"已知记忆：\n{existing_text}\n\n本轮对话：\n"
            f"用户说：{user_text[:800]}\n助手答：{assistant_text[:500]}",
        )
        start, end = raw.find("{"), raw.rfind("}")
        if start < 0 or end <= start:
            return
        diff = json.loads(raw[start:end + 1])
        if not isinstance(diff, dict):
            return

        def _match(old: str) -> int | None:
            """old 原文 → 现有记忆 id（精确或前缀匹配，防模型改写几个字导致匹配不上）"""
            old = (old or "").strip()
            for i, _, t in existing:
                if old and (t == old or t.startswith(old) or old.startswith(t)):
                    return i
            return None

        db = SessionLocal()
        try:
            active_texts = {t for _, _, t in existing}
            # add：校验 kind 白名单 + 长度 + 与现有记忆去重
            for item in diff.get("add") or []:
                if not isinstance(item, dict):
                    continue
                kind = str(item.get("kind") or "fact")
                content = str(item.get("content") or "").strip()
                if kind not in MEMORY_KINDS:
                    kind = "fact"
                if len(content) < 4 or len(content) > 180 or content in active_texts:
                    continue
                row = MemoryEntry(user_id=user_id, kind=kind,
                                  content=encrypt_memory(user_id, content))
                db.add(row)
                db.flush()
                active_texts.add(content)
            # update：旧条软删指向新条
            for item in diff.get("update") or []:
                if not isinstance(item, dict):
                    continue
                old_id = _match(str(item.get("old") or ""))
                content = str(item.get("content") or "").strip()
                if old_id is None or len(content) < 4 or len(content) > 180:
                    continue
                kind = str(item.get("kind") or "fact")
                if kind not in MEMORY_KINDS:
                    kind = "fact"
                row = MemoryEntry(user_id=user_id, kind=kind,
                                  content=encrypt_memory(user_id, content))
                db.add(row)
                db.flush()
                old_row = db.get(MemoryEntry, old_id)
                if old_row is not None:   # 期间被删等极端情况：跳过，不影响其他记忆
                    old_row.superseded_by = row.id
            # forget：旧条软删（-1 = 直接废弃，无替代）
            for old in diff.get("forget") or []:
                old_id = _match(str(old))
                old_row = db.get(MemoryEntry, old_id) if old_id is not None else None
                if old_row is not None:
                    old_row.superseded_by = -1
            db.commit()
            # 活跃条数超上限：淘汰低重要 + 最旧（硬删，腾出真实空间）
            ids = db.scalars(
                select(MemoryEntry.id)
                .where(MemoryEntry.user_id == user_id,
                       MemoryEntry.superseded_by.is_(None))
                .order_by(MemoryEntry.importance.asc(), MemoryEntry.id.asc())).all()
            stale = ids[MEMORY_KEEP:]
            if stale:
                db.execute(delete(MemoryEntry).where(MemoryEntry.id.in_(stale)))
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
    from ..models import MemoryEntry
    from .memory_crypto import decrypt_memory
    rows = db.scalars(
        select(MemoryEntry)
        .where(MemoryEntry.user_id == user.id, MemoryEntry.superseded_by.is_(None))
        .order_by(MemoryEntry.importance.desc(), MemoryEntry.id.desc())
        .limit(30)).all()
    facts = [t for r in rows if (t := decrypt_memory(user.id, r.content))]
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
    # 长期记忆注入：按"最近一条用户消息"的相关性检索 top-8（哈希嵌入余弦），
    # 替代旧的"盲取最新N条"——记忆有上限，盲取会视野截断：存了很多条但每次
    # 只看得见几条，与当前话题相关的旧私事（如花生过敏）可能刚好不在其中。
    # 后台任务执行时 query 即任务标题，任务相关记忆必被召回。
    # V2：记忆密文落库（MemoryEntry），解密后带 kind 交给 prompt 分组渲染。
    db = SessionLocal()
    try:
        rows = db.scalars(
            select(MemoryEntry)
            .where(MemoryEntry.user_id == user.id, MemoryEntry.superseded_by.is_(None))
            .order_by(MemoryEntry.importance.desc(), MemoryEntry.id.desc())
        ).all()
        all_mem = [(r.kind, t) for r in rows if (t := decrypt_memory(user.id, r.content))]
        query_text = next((m.content for m in reversed(history) if m.role == "user" and m.content), "")
        memories = _select_memories(all_mem, query_text)
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

    # 本次请求是否带图：带图消息（拍照识别）自动切「图像理解模型」做场景路由，
    # 未配置 llm_vision_model 时跟随主模型；非 200 时也用于区分"模型不支持识图"与普通网络错误
    has_images = any(m["role"] == "user" and isinstance(m.get("content"), list) for m in payload_messages)
    effective_model = settings.llm_vision_model if (has_images and settings.llm_vision_model) else settings.llm_model

    body = {
        "model": effective_model,
        "messages": payload_messages,
        "tools": tools_payload,
        "temperature": 0.6,
        # agnes-2.5-flash 是推理模型：思考链(reasoning)也计 token，给足余量防止答案被截断
        "max_tokens": 1600,
    }
    # GLM 系（glm-4.7-flash 等）默认开思考模式：ReAct 循环本身就是外置思考，内部思考
    # 纯浪费——响应慢、输出 token 翻倍、免费档 TPM 更易撞墙。对 glm 前缀模型显式关掉。
    if effective_model.lower().startswith("glm"):
        body["thinking"] = {"type": "disabled"}
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {settings.llm_api_key}",
    }

    last_error: EngineError | None = None
    last_was_rate_limit = False
    for attempt in range(4):
        if attempt:
            # 429 是分钟窗口限流：短退避熬不过窗口，用长退避 9s/15s/21s 跨约 45s；
            # 5xx/网络抖动用短退避 1.5s/3s 快速重试
            delay = attempt * 6.0 + 3.0 if last_was_rate_limit else 1.5 * attempt
            await asyncio.sleep(delay)
            last_was_rate_limit = False
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
            last_was_rate_limit = resp.status_code == 429
            last_error = EngineError("rate_limited" if last_was_rate_limit else "network")
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
