# MARK: - Agent 工具注册表（翻译自 AgentTools.swift）
# 每个 AgentTool = 给模型看的"说明书"（JSON Schema）+ 实际执行函数。
# 设计原则与 V1 一致：模型只负责"决定调什么、传什么参数"，所有数据读写都在
# 服务端完成，LLM 拿到的只有工具执行后的摘要文本。
# 与 V1 的差异：数据源从 iOS DataManager（本地 JSON）换成 PostgreSQL（按 user_id 隔离）。
import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timezone
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..config import settings
from ..models import AgentTask, AgentWrite, Course, CourseDoc, Homework, LedgerEntry, Parcel, StudyPlan, SyncedAssignment, User
from .browser import browse
from .embeddings import embed
from .sms_parser import extract_tracking_number, parse_sms
from .week import current_week_number

# 记账六分类（与 iOS 语音记账模块保持一致）
LEDGER_CATEGORIES = ["餐饮", "日用", "学习", "娱乐", "交通", "其他"]

# 模式 11 结构化卡片：客户端已实现渲染的卡片类型（jump=外部服务跳转卡，端侧白名单拼 URL）
CARD_TYPES = ["homework", "schedule", "bill", "jump"]

_WEEKDAYS_CN = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

_EMPTY_SCHEMA: dict[str, Any] = {"type": "object", "properties": {}}


@dataclass
class AgentTool:
    name: str
    description: str
    parameters: dict = field(default_factory=lambda: dict(_EMPTY_SCHEMA))
    # 入参：模型给的参数字典 / 当前用户 / 数据库会话 → 返回给模型的摘要文本
    execute: Callable[[dict, User, Session], Awaitable[str]] = None  # type: ignore


# ── 小工具函数 ────────────────────────────────────────

def _time_to_minutes(hhmm: str) -> int:
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def _week_courses_match(course_week_parity: str, week: int) -> bool:
    """单双周过滤：all 全上；single 仅单周；double 仅双周"""
    if course_week_parity == "single":
        return week % 2 == 1
    if course_week_parity == "double":
        return week % 2 == 0
    return True


def _fmt_money(v: float) -> str:
    return f"{v:.1f}"


# ── 工具集组装 ────────────────────────────────────────

def build_tools() -> list[AgentTool]:
    """组装工具全集（工具说明书与用户无关；user/db 在执行时经 run_tool 传入）"""
    return [
        # ── 1. 查今日课表 ──────────────────────────────
        AgentTool(
            name="get_today_schedule",
            description="查询用户今天（按当前学期周数过滤单双周）的全部课程，含时间、教室、老师。",
            execute=_today_schedule,
        ),
        # ── 2. 查下一节课 ──────────────────────────────
        AgentTool(
            name="get_next_class",
            description="查询当前正在上的课或下一节课（含开始时间和教室）。用户问'接下来有什么课/现在该去哪'时使用。",
            execute=_next_class,
        ),
        # ── 3. 查未完成作业 ────────────────────────────
        AgentTool(
            name="get_pending_homeworks",
            description="查询全部未完成的作业/待办（按截止时间排序，最紧急在前）。用户问'我有什么事没做/DDL'时使用。",
            execute=_pending_homeworks,
        ),
        # ── 4. 添加作业（确认卡：客户端用户点头后才写入手机本地）───
        AgentTool(
            name="add_homework",
            description="为用户添加一条作业/待办。用户说'帮我记一下要做XX'时使用。dueDate 格式为 yyyy-MM-dd HH:mm，用户没说截止时间就不传。工具不会直接写入——会先弹一张确认卡给用户，用户点头后自动生效，你只需口头确认内容并提醒用户点一下卡片。",
            parameters={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "作业标题，如：高数第三章习题"},
                    "courseName": {"type": "string", "description": "关联课程名，可选"},
                    "dueDate": {"type": "string", "description": "截止时间，格式 yyyy-MM-dd HH:mm，可选"},
                },
                "required": ["title"],
            },
            execute=_add_homework,
        ),
        # ── 5. 从短信/文本解析快递并入库 ───────────────
        AgentTool(
            name="add_parcel_from_sms",
            description="把用户粘贴的取件短信/通知文本解析出取件码和驿站，自动记入快递列表。用户说'帮我记一下这个快递'并附上短信内容时使用。",
            parameters={
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "快递短信/通知的完整原文"},
                },
                "required": ["text"],
            },
            execute=_add_parcel_from_sms,
        ),
        # ── 6. 记一笔账（确认卡：客户端用户点头后才写入手机本地）───
        AgentTool(
            name="add_ledger_entry",
            description=f"帮用户记一笔消费。用户说'午饭花了15块'这类话时使用。category 必须是：{'/'.join(LEDGER_CATEGORIES)} 之一。工具不会直接写入——会先弹一张确认卡给用户，用户点头后自动生效，你只需口头确认金额并提醒用户点一下卡片。",
            parameters={
                "type": "object",
                "properties": {
                    "amount": {"type": "number", "description": "金额（元），正数"},
                    "category": {"type": "string", "description": f"分类：{'/'.join(LEDGER_CATEGORIES)}"},
                    "note": {"type": "string", "description": "备注，如：午饭"},
                },
                "required": ["amount"],
            },
            execute=_add_ledger_entry,
        ),
        # ── 7. 查本月消费 ──────────────────────────────
        AgentTool(
            name="get_month_expense",
            description="查询本月消费总额与各分类占比。用户问'这个月花了多少/钱都花哪了'时使用。",
            execute=_month_expense,
        ),
        # ── 8. 查今日步数 ──────────────────────────────
        AgentTool(
            name="get_step_count",
            description="查询用户今天的步数（手机端上报）。用户问'今天走了多少步/步数够了吗'时使用。",
            execute=_step_count,
        ),
        # ── 9. 查天气 ──────────────────────────────────
        AgentTool(
            name="get_weather",
            description="查询今天的天气与温度（Open-Meteo 数据）。用户问'今天天气怎么样/要不要带伞'时使用。",
            execute=_weather,
        ),
        # ── 16. 查快递实时物流 ──────────────────────────
        AgentTool(
            name="get_parcel_status",
            description="查询快递的实时物流状态（快递100 数据）。用户问'我的快递到哪了/物流怎么样'时使用。trackingNumber 不传时自动追踪最近的待取件快递单号。",
            parameters={
                "type": "object",
                "properties": {
                    "trackingNumber": {"type": "string", "description": "快递单号，可选；不传则查最近一条带单号的待取件快递"},
                },
            },
            execute=_parcel_status,
        ),
        # ── 10. 撤销最近一次写入 ────────────────────────
        AgentTool(
            name="undo_last_write",
            description="撤销你最近一次替用户写入的数据（刚加的作业/记的账/记的快递/刚标记完成）。用户说'撤了它/撤销/记错了删掉'时使用。",
            execute=_undo_last_write,
        ),
        # ── 11. 课程资料入库（RAG 写入）─────────────────
        AgentTool(
            name="add_course_material",
            description="把一段课程资料（课件摘录/笔记/老师讲的重点）存入用户的资料库，以后可以检索。用户说'把这段存进资料库/记一下这个知识点'并附上内容时使用。",
            parameters={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "资料标题，如：高数第三章 泰勒公式"},
                    "content": {"type": "string", "description": "资料正文原文（不要改写，保留原样）"},
                },
                "required": ["title", "content"],
            },
            execute=_add_course_material,
        ),
        # ── 12. 课程资料检索（RAG 读取）─────────────────
        AgentTool(
            name="search_course_materials",
            description="在用户的课程资料库里按语义检索相关段落（余弦相似 top-3）。资料库支持整份课件文件（PDF/Word/PPT 自动分块）和单条笔记，检索结果会标注出自哪个文件哪一段。用户问'老师讲过XX吗/我的笔记里有没有XX'或回答需要引用资料时使用。资料库为空时工具会提示。",
            parameters={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "检索的问题或关键词"},
                },
                "required": ["query"],
            },
            execute=_search_course_materials,
        ),
        # ── 13. 生成复习计划 ────────────────────────────
        AgentTool(
            name="create_study_plan",
            description="为用户制定按天的复习/学习计划：把目标拆成每天的具体任务并落库（任务同时进入作业列表跟踪完成）。用户说'帮我做一个XX复习计划'时使用。你必须自己把目标合理拆分成逐日任务。",
            parameters={
                "type": "object",
                "properties": {
                    "goal": {"type": "string", "description": "计划目标，如：期末高数复习"},
                    "tasks": {
                        "type": "array",
                        "description": "逐日任务列表，每项 {date: yyyy-MM-dd, task: 当天任务}",
                        "items": {
                            "type": "object",
                            "properties": {
                                "date": {"type": "string", "description": "yyyy-MM-dd"},
                                "task": {"type": "string", "description": "当天要完成的任务"},
                            },
                            "required": ["date", "task"],
                        },
                    },
                },
                "required": ["goal", "tasks"],
            },
            execute=_create_study_plan,
        ),
        # ── 14. 对照复习计划进度 ────────────────────────
        AgentTool(
            name="check_study_plan",
            description="查询当前进行中的复习计划：今日任务、整体完成度、逾期未完成的任务。用户问'计划进度怎么样/今天该复习什么'时使用。基于结果给出鼓励或动态调整建议（如顺延、加量）。",
            execute=_check_study_plan,
        ),
        # ── 15. 标记作业完成 ────────────────────────────
        AgentTool(
            name="mark_homework_done",
            description="把一条未完成作业标记为已完成。用户说'XX做完了/交了/搞定了'时使用。title 传作业标题中的关键词；匹配到多条时先列出让用户确认。",
            parameters={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "作业标题关键词，如：实验报告"},
                },
                "required": ["title"],
            },
            execute=_mark_homework_done,
        ),
        # ── 16. 异步定时任务（Muse 式"关掉 App 还在干活"）──
        AgentTool(
            name="create_task",
            description=(
                "创建异步定时任务：到点后服务器自动执行并把汇报放进任务中心，用户打开 App 会收到通知。"
                "用户提出'定时/定期做某事'（如'每天早上8点总结今天的课''周三晚上提醒我复习高数'）时使用。"
                "title 写清楚要做的事，将来会原样交给 Agent 独立执行，必须自包含（别写'上面说的'这种指代）。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "任务指令（自包含），如：看看今天的课表并给出一句安排建议"},
                    "scheduleKind": {"type": "string", "enum": ["daily", "once"],
                                     "description": "daily=每天定时执行，once=到指定时刻执行一次"},
                    "runTime": {"type": "string", "description": "daily 必填：执行时刻，北京时间 HH:MM，如 08:00"},
                    "runAt": {"type": "string", "description": "once 必填：执行时刻，北京时间，如 2026-10-08 20:00"},
                },
                "required": ["title", "scheduleKind"],
            },
            execute=_create_task,
        ),
        AgentTool(
            name="list_tasks",
            description="查看进行中的异步定时任务列表（用户问'我让你定期做的事/定时任务有哪些'时使用）。",
            execute=_list_tasks,
        ),
        # ── 17. 结构化卡片（模式 11：Agent 输出 = UI）────
        AgentTool(
            name="show_card",
            description=(
                "把查询结果渲染成一张可点击的卡片插入聊天（作业卡/课表卡/账单卡/外部服务跳转卡）。"
                "刚查完作业列表/今日课表/本月账单后，回答文字前先调本工具，"
                "items 直接从工具结果里提取，用户点卡片可直达对应页面。"
                "cardType=jump：用户让你订酒店/机票、点奶茶外卖、网购时（你不能代下单付款），"
                "platform 传 meituan/eleme/ctrip/dianping/taobao/jd/12306/fliggy 之一，"
                "query 写要买/搜的东西，items 传 1 条操作提示，summary 写'打开平台自己选品付款'。"
                "不要对问答、闲聊、写操作结果使用。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "cardType": {
                        "type": "string", "enum": list(CARD_TYPES),
                        "description": "卡片类型：homework=作业/DDL 列表卡，schedule=今日课表卡，bill=本月账单卡，jump=外部服务跳转卡",
                    },
                    "title": {"type": "string", "description": "卡片标题，如：今日课表 / 未完成作业 / 本月账单"},
                    "items": {
                        "type": "array",
                        "description": "卡片条目（从工具结果原样提取，最多 12 条）",
                        "items": {
                            "type": "object",
                            "properties": {
                                "primary": {"type": "string", "description": "主标题：课程名/作业名/分类名"},
                                "secondary": {"type": "string", "description": "次要信息：时间/截止时间/金额"},
                                "tertiary": {"type": "string", "description": "补充信息：教室/关联课程/笔数，可选"},
                            },
                            "required": ["primary"],
                        },
                    },
                    "summary": {"type": "string", "description": "底部汇总行，如：共 3 节课 / 本月共 ¥158.0，可选"},
                    "platform": {"type": "string", "description": "jump 卡必填：meituan/eleme/ctrip/dianping/taobao/jd/12306/fliggy 之一"},
                    "query": {"type": "string", "description": "jump 卡：要买/搜的东西，如：奶茶 / 杭州 酒店"},
                },
                "required": ["cardType", "items"],
            },
            execute=_show_card,
        ),
        # ── 18. 用户文件柜：保存 ────────────────────────
        AgentTool(
            name="save_file",
            description=(
                "把一段内容保存成主人的文件（存在服务器文件柜里，App 界面看不到列表，需要时你读出来讲给他听）。"
                "主人说'帮我存成文件/写个文档/记到文件里'，或内容较长值得存档（整理的笔记、报告草稿、"
                "上网查到的资料）时使用；同名会覆盖。文件名见名知义并带扩展名，如：高数复习笔记.md。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "文件名（可带扩展名），如：复习笔记.md"},
                    "content": {"type": "string", "description": "文件全文（纯文本）"},
                },
                "required": ["name", "content"],
            },
            execute=_save_file,
        ),
        # ── 19. 用户文件柜：读取 ────────────────────────
        AgentTool(
            name="read_file",
            description="读取主人文件柜里某个文件的内容。主人说'读一下/打开XX文件'时使用；不确定文件名就先 list_files。",
            parameters={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "文件名（与保存时一致）"},
                },
                "required": ["name"],
            },
            execute=_read_file,
        ),
        # ── 20. 用户文件柜：列表 ────────────────────────
        AgentTool(
            name="list_files",
            description="列出主人文件柜里的全部文件（文件名/大小/改动时间）。主人问'我存了哪些文件'时使用。",
            execute=_list_files,
        ),
        # ── 21. 网页浏览（只读）────────────────────────
        AgentTool(
            name="browse_url",
            description=(
                "打开一个网页链接并阅读正文（自动转成精简 Markdown）。"
                "主人说'上网查一下/看看这个网页/帮我读这篇链接'时使用。"
                "只能读：不能登录、填表单或下单；拿到的正文可直接总结或回答。"
            ),
            parameters={
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "网页链接，如 https://example.com/article"},
                },
                "required": ["url"],
            },
            execute=_browse_url,
        ),
        # ── 22. 技能库：列表 ────────────────────────────
        AgentTool(
            name="list_skills",
            description="列出技能库里可用的流程技能（如复习计划方法、账单分析）。遇到复习计划/周报/账单分析这类流程型任务，先看看有没有对应技能。",
            execute=_list_skills,
        ),
        # ── 23. 技能库：读取 ────────────────────────────
        AgentTool(
            name="load_skill",
            description="读取一个技能的完整说明书（分步流程）。读完必须严格照步骤执行。",
            parameters={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "技能名（list_skills 里列出的名字）"},
                },
                "required": ["name"],
            },
            execute=_load_skill,
        ),
        # ── 24. 联网搜索 ────────────────────────────────
        AgentTool(
            name="web_search",
            description="联网搜索实时信息（考试时间/新闻/政策/攻略等），返回摘要与来源链接。需要更多细节时再用 browse_url 打开具体网页。",
            parameters={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "搜索关键词，精炼成短语（如：2026 全国计算机等级考试 报名时间）"},
                },
                "required": ["query"],
            },
            execute=_web_search,
        ),
    ]


# ── 各工具实现 ────────────────────────────────────────

def _confirmation_card(action: str, title: str, lines: list[str], params: dict) -> str:
    """写操作统一出口：不落库，打包成确认卡 JSON。
    引擎识别后以 kind="confirmation" 推给客户端渲染；用户点头后由客户端本地写入
    （数据同源：写永远发生在手机本地，服务器库不再重复记账/作业）。"""
    return json.dumps({"confirmation": {
        "action": action, "title": title, "lines": lines, "params": params,
    }}, ensure_ascii=False)


async def _today_schedule(args: dict, user: User, db: Session) -> str:
    week = current_week_number(user.semester_start_date)
    if week is None:
        return "尚未设置开学日期，无法确定当前周数。建议用户到设置页设置开学日期。"
    today_dow = datetime.now().isoweekday()  # 1=周一 … 7=周日
    rows = db.scalars(
        select(Course)
        .where(Course.user_id == user.id, Course.day_of_week == today_dow)
        .order_by(Course.start_time)
    ).all()
    todays = [c for c in rows if _week_courses_match(c.week_parity, week)]
    if not todays:
        return f"今天（{_WEEKDAYS_CN[today_dow - 1]}）没有课，是空闲日。"
    lines = [
        f"{c.start_time}-{c.end_time} 《{c.name}》{'教室未填' if not c.location else '@' + c.location}"
        + (f" · {c.teacher}" if c.teacher else "")
        for c in todays
    ]
    return f"今天是学期第{week}周，{_WEEKDAYS_CN[today_dow - 1]}。今日课程：\n" + "\n".join(lines)


async def _next_class(args: dict, user: User, db: Session) -> str:
    week = current_week_number(user.semester_start_date)
    if week is None:
        return "尚未设置开学日期，无法查询课程。"
    now = datetime.now()
    today_dow = now.isoweekday()
    rows = db.scalars(
        select(Course).where(Course.user_id == user.id, Course.day_of_week == today_dow)
    ).all()
    todays = sorted(
        (c for c in rows if _week_courses_match(c.week_parity, week)),
        key=lambda c: _time_to_minutes(c.start_time),
    )
    current = next(
        (c for c in todays
         if _time_to_minutes(c.start_time) <= now.hour * 60 + now.minute < _time_to_minutes(c.end_time)),
        None,
    )
    if current:
        return (f"当前正在上课：《{current.name}》{current.start_time}-{current.end_time}，"
                f"教室：{current.location or '未填'}。")
    nxt = next(
        (c for c in todays if _time_to_minutes(c.start_time) > now.hour * 60 + now.minute),
        None,
    )
    if nxt:
        start_dt = datetime.combine(now.date(), time.fromisoformat(nxt.start_time))
        mins = int((start_dt - now).total_seconds() // 60)
        return (f"当前没有课。下一节：《{nxt.name}》{nxt.start_time} 开始"
                f"（约 {max(0, mins)} 分钟后），教室：{nxt.location or '未填'}。")
    return "今天接下来的课程已全部结束。"


async def _pending_homeworks(args: dict, user: User, db: Session) -> str:
    pending = db.scalars(
        select(Homework)
        .where(Homework.user_id == user.id, Homework.is_done.is_(False))
        .order_by(Homework.due_date.asc().nullslast())
    ).all()
    # 平台同步的作业（学习通等）一并纳入：Agent 提醒 DDL 时看得全
    synced = db.scalars(
        select(SyncedAssignment)
        .where(SyncedAssignment.user_id == user.id, SyncedAssignment.is_done.is_(False))
        .order_by(SyncedAssignment.due_date.asc().nullslast())
    ).all()
    if not pending and not synced:
        return "没有未完成的作业，全部清空！🎉"
    lines = []
    for hw in pending:
        if hw.due_date:
            overdue = "（已过期！）" if hw.due_date < datetime.now() else ""
            course = f" · {hw.course_name}" if hw.course_name else ""
            lines.append(f"《{hw.title}》截止 {hw.due_date:%m月%d日 %H:%M}{overdue}{course}")
        else:
            lines.append(f"《{hw.title}》（无截止时间）")
    platform_names = {"chaoxing": "学习通", "zhihuishu": "智慧树"}
    for s in synced:
        src = platform_names.get(s.platform, s.platform)
        if s.due_date:
            overdue = "（已过期！）" if s.due_date < datetime.now() else ""
            lines.append(f"《{s.title}》截止 {s.due_date:%m月%d日 %H:%M}{overdue} · {s.course_name or ''}（来自{src}）".replace(" ·  ", " · "))
        else:
            lines.append(f"《{s.title}》（无截止时间）· {s.course_name or ''}（来自{src}）".replace(" ·  ", " · "))
    total = len(pending) + len(synced)
    return f"未完成作业 {total} 个：\n" + "\n".join(lines)


async def _add_homework(args: dict, user: User, db: Session) -> str:
    title = args.get("title")
    if not title or not str(title).strip():
        raise ToolError("缺少必需参数：title")
    lines = [f"内容：《{str(title).strip()}》"]
    if course := str(args.get("courseName") or "").strip():
        lines.append(f"课程：{course}")
    due = None
    if due_str := args.get("dueDate"):
        due = _parse_due_date(str(due_str))
        if due:
            lines.append(f"截止 {due:%m月%d日 %H:%M}")
        else:
            # 模式 9：时间解析失败不静默丢弃——原样展示在确认卡上让用户自己核对
            lines.append(f"截止时间「{due_str}」（没解析出来，确认时请留意）")
    return _confirmation_card("add_homework", "记一条待办", lines, args)


def _parse_due_date(s: str) -> datetime | None:
    """宽松解析截止时间：模型被要求给 yyyy-MM-dd HH:mm，但偶尔会漏时间或带中文"""
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d", "%Y/%m/%d %H:%M", "%Y/%m/%d",
                "%m月%d日 %H:%M", "%m月%d日%H:%M", "%m月%d日"):
        try:
            d = datetime.strptime(s.strip(), fmt)
            if "%H" not in fmt:
                d = d.replace(hour=22, minute=0)  # 只给了日期：默认当天 22:00 截止
            return d
        except ValueError:
            continue
    return None


def _log_write(db: Session, user_id: int, entity: str, entity_id: int, summary: str) -> None:
    """写操作流水（交互原则 8）：撤销功能的数据源；流水失败不影响主写入"""
    try:
        db.add(AgentWrite(user_id=user_id, entity=entity, entity_id=entity_id,
                          summary=summary[:190]))
    except Exception:
        pass


async def _add_parcel_from_sms(args: dict, user: User, db: Session) -> str:
    text = args.get("text")
    if not text or not str(text).strip():
        raise ToolError("缺少必需参数：text")
    parsed = parse_sms(str(text))
    if parsed is None:
        return "没能从这段文字里识别出取件码（需要类似 3-2-5088 的格式），请用户手动到事务页记录。"
    code, station = parsed
    tracking = extract_tracking_number(str(text))
    parcel = Parcel(user_id=user.id, code=code, station=station or "未识别驿站",
                    tracking_no=tracking)
    db.add(parcel)
    db.flush()
    _log_write(db, user.id, "parcel", parcel.id, f"快递 {code}")
    db.commit()
    track_note = f"，单号 {tracking}" if tracking else ""
    return (f"已记入快递：取件码 {code}，驿站 {station or '未识别'}{track_note}。"
            + ("之后可以问'我的快递到哪了'查实时物流。" if tracking else ""))


# ── 快递实时查询（扩展点：快递真追踪）──────────────────
# 实测结论（2026-09）：query 接口免 key 可用；autonumber 识别接口要 key，
# 故承运商改为"字母前缀映射 + 常见公司依次试探"。接口异常时如实降级提示，
# 绝不编造物流状态。
_CARRIER_NAMES = {
    "shunfeng": "顺丰", "zhongtong": "中通", "yuantong": "圆通",
    "yunda": "韵达", "jitu": "极兔", "ems": "邮政EMS", "youzhengguonei": "邮政",
    "jd": "京东", "debangkuaidi": "德邦", "tiantian": "天天", "huitongkuaidi": "百世",
    "shentong": "申通", "annengwuliu": "安能",
}
_PREFIX_TO_COM = [  # 常见字母前缀 → comCode（按命中率排序）
    ("SF", "shunfeng"), ("JDV", "jd"), ("JD", "jd"), ("JT", "jitu"),
    ("YT", "yuantong"), ("ZTO", "zhongtong"), ("STO", "shentong"),
    ("YD", "yunda"), ("EMS", "ems"), ("DB", "debangkuaidi"), ("DPK", "debangkuaidi"),
]
_GUESS_ORDER = ["zhongtong", "yuantong", "yunda", "shunfeng", "ems", "jitu", "shentong"]


def _candidate_companies(tracking_no: str) -> list[str]:
    """单号 → 候选承运商列表：字母前缀直判；纯数字走常见公司试探"""
    upper = tracking_no.upper()
    for prefix, com in _PREFIX_TO_COM:
        if upper.startswith(prefix) and len(upper) > len(prefix):
            return [com]
    return list(_GUESS_ORDER)  # 纯数字：常见公司依次试探


async def _query_express(tracking_no: str) -> str:
    """调快递100 免 key query 接口查轨迹，返回摘要文本（任何失败降级为友好提示）"""
    headers = {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"}
    async with httpx.AsyncClient(timeout=8, headers=headers) as client:
        for com in _candidate_companies(tracking_no):
            try:
                resp = await client.get("https://www.kuaidi100.com/query",
                                        params={"type": com, "postid": tracking_no})
                data = resp.json() if resp.status_code == 200 else {}
            except Exception:  # noqa: BLE001 —— 网络波动/接口改版都降级，不中断 ReAct
                return f"物流查询暂时失败（查询通道不稳定），单号 {tracking_no} 稍后再问一次。"
            events = data.get("data") or []
            if data.get("status") == "200" and events and "查无结果" not in str(events[0].get("context", "")):
                carrier = _CARRIER_NAMES.get(com, com)
                lines = [f"「{carrier}」{tracking_no} 最新动态（{len(events)} 条轨迹）：",
                         f"· {events[0].get('ftime', events[0].get('time', ''))} {events[0].get('context', '')}"]
                lines += [f"· {e.get('ftime', e.get('time', ''))} {e.get('context', '')}" for e in events[1:3]]
                return "\n".join(lines)
    return (f"单号 {tracking_no} 在常见快递公司都查不到轨迹"
            "（可能还没揽收、单号有误，或是不常见的承运商）。等商家发货后再问我一次。")


async def _parcel_status(args: dict, user: User, db: Session) -> str:
    """查快递实时状态：优先用参数里的单号，否则找最近的待取件带单号包裹"""
    tracking = str(args.get("trackingNumber") or "").strip()
    if not tracking:
        parcel = db.scalar(
            select(Parcel)
            .where(Parcel.user_id == user.id, Parcel.is_picked.is_(False),
                   Parcel.tracking_no.is_not(None))
            .order_by(Parcel.id.desc()).limit(1)
        )
        if parcel is None:
            return ("当前没有可以追踪的快递单号（取件短信里的单号我没记住）。"
                    "把单号发给我，或者等下次有新取件短信时让我记快递。")
        tracking = parcel.tracking_no
    return await _query_express(tracking)


async def _add_ledger_entry(args: dict, user: User, db: Session) -> str:
    amount = _number_value(args.get("amount"))
    if amount <= 0:
        raise ToolError("缺少必需参数：amount")
    category = args.get("category")
    if not category or str(category) not in LEDGER_CATEGORIES:
        # 分类没给就归入"其他"，写进确认卡让用户自己核对（不悄悄替用户做主）
        category = "其他"
    lines = [f"金额：¥{_fmt_money(amount)}", f"分类：{category}"]
    if note := str(args.get("note") or "").strip():
        lines.append(f"备注：{note}")
    return _confirmation_card("add_ledger", "记一笔账", lines, args)


async def _month_expense(args: dict, user: User, db: Session) -> str:
    now = date.today()
    month_start = now.replace(day=1)
    rows = db.execute(
        select(LedgerEntry.category, func.sum(LedgerEntry.amount), func.count())
        .where(LedgerEntry.user_id == user.id,
               LedgerEntry.created_at >= datetime.combine(month_start, time.min))
        .group_by(LedgerEntry.category)
        .order_by(func.sum(LedgerEntry.amount).desc())
    ).all()
    if not rows:
        return "本月还没有任何记账记录。"
    total = float(sum(r[1] for r in rows))
    count = sum(r[2] for r in rows)
    lines = [f"· {cat}：¥{_fmt_money(float(s))}（{int(float(s) / total * 100)}%）"
             for cat, s, _ in rows]
    return f"本月共消费 ¥{_fmt_money(total)}（{count} 笔）：\n" + "\n".join(lines)


async def _step_count(args: dict, user: User, db: Session) -> str:
    # 步数由 iOS 端上报入库；跨天未上报则视为 0
    if user.steps_date != date.today():
        steps = 0
    else:
        steps = user.today_steps
    text = f"今天已走 {steps} 步。"
    if steps >= 10000:
        text += "已达成 10000 步满奖励！"
    elif steps >= 6000:
        text += f"已达 6000 步，再走 {10000 - steps} 步可拿满奖励。"
    else:
        text += f"距离 6000 步目标还差 {6000 - steps} 步。"
    return text


# WMO 天气代码 → 中文描述（Open-Meteo 返回 weather_code）
_WMO_TEXT = {
    0: "晴", 1: "基本晴", 2: "多云", 3: "阴",
    45: "有雾", 48: "有雾（结冰）",
    51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
    61: "小雨", 63: "中雨", 65: "大雨",
    71: "小雪", 73: "中雪", 75: "大雪",
    80: "阵雨", 81: "中阵雨", 82: "强阵雨",
    95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "强雷阵雨伴冰雹",
}


async def _weather(args: dict, user: User, db: Session) -> str:
    if user.latitude is None or user.longitude is None:
        return "还没有上报过位置信息，无法查天气（打开 App 允许定位即可）。"
    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude": user.latitude,
        "longitude": user.longitude,
        "daily": "weather_code,temperature_2m_max,temperature_2m_min",
        "timezone": "auto",
        "forecast_days": 1,
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url, params=params)
            resp.raise_for_status()
            daily = resp.json()["daily"]
    except Exception:
        return "天气数据暂时获取失败（可能是网络问题）。"
    code = daily["weather_code"][0]
    tmin = round(daily["temperature_2m_min"][0])
    tmax = round(daily["temperature_2m_max"][0])
    desc = _WMO_TEXT.get(int(code), "天气未知")
    rainy = int(code) >= 51  # 51 起为各类降水
    return (f"今天{desc}，气温 {tmin}~{tmax}℃"
            + ("，有降水，建议带伞☂️" if rainy else "") + "。")


# ── 模式 9 / 7 / 8 的新增工具实现 ──────────────────────

async def _undo_last_write(args: dict, user: User, db: Session) -> str:
    return perform_undo(user, db)


def perform_undo(user: User, db: Session) -> str:
    """撤销最近一次 Agent 写入（交互原则 8）——工具与 REST /agent/undo 共用

    按 agent_writes 流水找最近一条，按 entity 类型回滚：
      homework/parcel/ledger → 删行；homework_done → 改回未完成；task → 取消任务。"""
    row = db.scalar(
        select(AgentWrite).where(AgentWrite.user_id == user.id)
        .order_by(AgentWrite.id.desc()).limit(1)
    )
    if row is None:
        return "最近没有可以撤销的 AI 写入记录。"
    obj = None
    if row.entity in ("homework", "parcel", "ledger"):
        model_cls = {"homework": Homework, "parcel": Parcel, "ledger": LedgerEntry}[row.entity]
        obj = db.get(model_cls, row.entity_id)
        if obj is not None and obj.user_id != user.id:
            obj = None  # 越权保护：只动自己的数据
    elif row.entity == "homework_done":
        hw = db.get(Homework, row.entity_id)
        if hw is not None and hw.user_id == user.id:
            hw.is_done = False
    elif row.entity == "task":
        t = db.get(AgentTask, row.entity_id)
        if t is not None and t.user_id == user.id and t.status == "active":
            t.status = "cancelled"
            obj = t  # 确实撤掉了才置位；已完成/已取消的任务无可撤销
    if row.entity in ("homework", "parcel", "ledger") and obj is None:
        db.delete(row)  # 主记录已被手动删掉：流水也清掉，避免撤销卡死
        db.commit()
        return f"这条记录（{row.summary}）已经不存在了，流水已清理。"
    if row.entity == "task" and obj is None:
        db.delete(row)
        db.commit()
        return f"这条任务（{row.summary}）已完成、已取消或已删除，无需撤销。"
    db.delete(row)
    db.commit()
    return f"已撤销：{row.summary}。"


# ── 异步定时任务（Muse 式"关掉 App 还在干活"）──────────

async def _create_task(args: dict, user: User, db: Session) -> str:
    title = args.get("title")
    if not title or not str(title).strip():
        raise ToolError("缺少必需参数：title")
    title = str(title).strip()[:300]
    kind = str(args.get("scheduleKind") or "").strip()
    if kind not in ("daily", "once"):
        raise ToolError("scheduleKind 必须是 daily（每天定时）或 once（一次性）")
    # 惰性导入：scheduler 的加载链是 scheduler→engine→tools，函数内导入避免循环
    from .scheduler import bj_to_utc, next_daily_run

    now_utc = datetime.now(timezone.utc).replace(tzinfo=None)
    if kind == "daily":
        rt = str(args.get("runTime") or "").strip()
        try:
            hh, mm = rt.split(":")[:2]
            if not (0 <= int(hh) <= 23 and 0 <= int(mm) <= 59):
                raise ValueError
            run_time = f"{int(hh):02d}:{int(mm):02d}"
        except (ValueError, IndexError):
            return f"执行时刻「{rt}」没解析出来，格式要像 08:30。请用户给个明确的时刻再创建。"
        task = AgentTask(user_id=user.id, title=title, schedule_kind="daily",
                         run_time=run_time, next_run_at=next_daily_run(run_time))
        when_text = f"每天 {run_time}（北京时间）"
    else:
        target = _parse_due_date(str(args.get("runAt") or "").strip())
        if target is None:
            return "执行时刻没解析出来。请用户给明确的日期时间（如 2026-10-08 20:00）再创建。"
        next_run = bj_to_utc(target)
        if next_run <= now_utc:
            return "这个时刻已经过了。请用户给一个未来的时间再创建。"
        task = AgentTask(user_id=user.id, title=title, schedule_kind="once",
                         run_at=target, next_run_at=next_run)
        when_text = f"{target:%m月%d日 %H:%M}（北京时间）"
    db.add(task)
    db.flush()
    _log_write(db, user.id, "task", task.id, f"任务「{title[:60]}」（{when_text}）")
    db.commit()
    return (f"已创建定时任务：「{title}」，{when_text} 执行。"
            "到点我会自动干完，汇报放进任务中心，用户开 App 会收到通知。")


async def _list_tasks(args: dict, user: User, db: Session) -> str:
    rows = db.scalars(
        select(AgentTask).where(AgentTask.user_id == user.id, AgentTask.status == "active")
        .order_by(AgentTask.next_run_at).limit(20)
    ).all()
    if not rows:
        return "当前没有进行中的定时任务。用户想让我定期干活的话，说清楚'做什么+每天几点/哪天几点'就行。"
    lines = []
    for t in rows:
        when = (f"每天 {t.run_time}" if t.schedule_kind == "daily"
                else (f"{t.run_at:%m月%d日 %H:%M}" if t.run_at else "一次性"))
        err = " · ⚠️上次执行失败" if t.last_error else ""
        lines.append(f"#{t.id} 「{t.title}」 {when}（北京时间）{err}")
    return "进行中的定时任务：\n" + "\n".join(lines)


async def _add_course_material(args: dict, user: User, db: Session) -> str:
    title = args.get("title")
    content = args.get("content")
    if not title or not str(title).strip():
        raise ToolError("缺少必需参数：title")
    if not content or not str(content).strip():
        raise ToolError("缺少必需参数：content")
    content = str(content).strip()[:4000]
    doc = CourseDoc(user_id=user.id, title=str(title).strip()[:120],
                    content=content, vector=embed(content))
    db.add(doc)
    db.commit()
    return f"已把《{doc.title}》收进资料库（{len(content)} 字）。可以问'我的笔记里有没有XX'来检索。"


async def _search_course_materials(args: dict, user: User, db: Session) -> str:
    query = args.get("query")
    if not query or not str(query).strip():
        raise ToolError("缺少必需参数：query")
    rows = db.scalars(
        select(CourseDoc).where(CourseDoc.user_id == user.id)
        .order_by(CourseDoc.vector.cosine_distance(embed(str(query))))
        .limit(6)
    ).all()
    if not rows:
        return "资料库还是空的。请用户把课件/笔记发给我并说'存进资料库'，之后就能检索了。"
    # 文件课件一份几十块，按文件去重（每文件只留余弦最近的一块），防单个 PDF 刷屏
    seen_files: set[str] = set()
    picked: list[CourseDoc] = []
    for r in rows:
        if r.source_file:
            if r.source_file in seen_files:
                continue
            seen_files.add(r.source_file)
        picked.append(r)
        if len(picked) == 3:
            break
    blocks = [f"【{d.source_file}·第{(d.chunk_index or 0) + 1}段】{d.content[:400]}"
              if d.source_file else f"【{d.title}】{d.content[:300]}"
              for d in picked]
    return "从资料库检索到最相关的段落：\n\n" + "\n───\n".join(blocks)


async def _create_study_plan(args: dict, user: User, db: Session) -> str:
    goal = args.get("goal")
    tasks = args.get("tasks")
    if not goal or not str(goal).strip():
        raise ToolError("缺少必需参数：goal")
    if not isinstance(tasks, list) or not tasks:
        raise ToolError("缺少必需参数：tasks（逐日任务列表）")
    # 新计划生效，旧计划自动归档
    db.query(StudyPlan).filter(StudyPlan.user_id == user.id,
                               StudyPlan.is_active.is_(True)).update({"is_active": False})
    plan = StudyPlan(user_id=user.id, goal=str(goal).strip()[:120],
                     plan_json=json.dumps(tasks, ensure_ascii=False)[:3400])
    db.add(plan)
    created = 0
    for t in tasks[:30]:
        if not isinstance(t, dict):
            continue
        task_title = str(t.get("task") or "").strip()
        if not task_title:
            continue
        due = None
        if day := str(t.get("date") or "").strip():
            try:
                due = datetime.combine(datetime.strptime(day, "%Y-%m-%d").date(), time(22, 0))
            except ValueError:
                due = None
        hw = Homework(user_id=user.id, title=task_title[:120],
                      course_name="复习计划", due_date=due)
        db.add(hw)
        created += 1
    db.commit()
    return (f"已生成复习计划「{plan.goal}」：{created} 个任务（每天截止 22:00），"
            f"已同时加入作业列表。之后问'计划进度怎么样'可以对照检查。")


async def _check_study_plan(args: dict, user: User, db: Session) -> str:
    plan = db.scalar(
        select(StudyPlan).where(StudyPlan.user_id == user.id, StudyPlan.is_active.is_(True))
        .order_by(StudyPlan.id.desc()).limit(1)
    )
    if plan is None:
        return "还没有进行中的复习计划。用户想做的话，告诉我目标和时间范围来生成。"
    hws = db.scalars(
        select(Homework).where(Homework.user_id == user.id, Homework.course_name == "复习计划")
        .order_by(Homework.due_date.asc().nullslast())
    ).all()
    total, done = len(hws), sum(1 for h in hws if h.is_done)
    today = date.today()
    today_tasks = [h for h in hws if h.due_date and h.due_date.date() == today]
    overdue = [h for h in hws if not h.is_done and h.due_date and h.due_date.date() < today]
    lines = [f"进行中计划：{plan.goal}（进度 {done}/{total}）"]
    if today_tasks:
        lines.append("今天任务：" + "；".join(
            f"{'✅' if h.is_done else '⬜'}{h.title}" for h in today_tasks))
    else:
        lines.append("今天没有安排任务。")
    if overdue:
        lines.append("已逾期未完成：" + "；".join(h.title for h in overdue[:5]))
    return "\n".join(lines)


async def _mark_homework_done(args: dict, user: User, db: Session) -> str:
    title = args.get("title")
    if not title or not str(title).strip():
        raise ToolError("缺少必需参数：title")
    matches = db.scalars(
        select(Homework)
        .where(Homework.user_id == user.id, Homework.is_done.is_(False),
               Homework.title.ilike(f"%{str(title).strip()}%"))
        .order_by(Homework.due_date.asc().nullslast()).limit(3)
    ).all()
    if not matches:
        return f"未完成的作业里没找到带「{title}」的，请用户核对标题。"
    if len(matches) > 1:
        # 模式 9：多条命中不替用户做主——列出让用户确认
        listing = "；".join(f"《{h.title}》" for h in matches)
        return f"找到 {len(matches)} 条都带「{title}」：{listing}。请用户确认是哪一条，再精确指定。"
    hw = matches[0]
    hw.is_done = True
    db.flush()
    _log_write(db, user.id, "homework_done", hw.id, f"完成《{hw.title}》")
    db.commit()
    return f"已完成：《{hw.title}》。"


async def _show_card(args: dict, user: User, db: Session) -> str:
    """模式 11：结构化卡片。校验并规整模型给的卡片参数 → 返回卡片 JSON 字符串。

    引擎检测到本工具的合法 JSON 结果时，会以 kind="card" 推给客户端渲染；
    回填给模型的只是"已插入"确认，防止模型把卡片数据再用文字复述一遍。"""
    card_type = str(args.get("cardType") or "").strip()
    if card_type not in CARD_TYPES:
        return f"卡片参数不合法：cardType 必须是 {'/'.join(CARD_TYPES)} 之一。"
    raw_items = args.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        return "卡片参数不合法：items 至少需要 1 条。"
    items = []
    for raw in raw_items[:12]:
        if not isinstance(raw, dict):
            continue
        primary = str(raw.get("primary") or "").strip()
        if not primary:
            continue
        items.append({
            "primary": primary[:40],
            "secondary": str(raw.get("secondary") or "")[:60],
            "tertiary": str(raw.get("tertiary") or "")[:60],
        })
    if not items:
        return "卡片参数不合法：items 里没有任何有效条目（每条需要非空 primary）。"
    card = {
        "cardType": card_type,
        "title": (str(args.get("title") or "").strip() or {
            "homework": "未完成作业", "schedule": "今日课表", "bill": "本月账单",
            "jump": "去完成",
        }[card_type])[:24],
        "platform": str(args.get("platform") or "").strip()[:20],
        "query": str(args.get("query") or "").strip()[:40],
        "items": items,
    }
    if summary := str(args.get("summary") or "").strip():
        card["summary"] = summary[:60]
    return json.dumps(card, ensure_ascii=False)


# ── 用户文件柜（Muse 式文件系统：服务器上每用户一个目录）──
_FILE_NAME_RE = re.compile(r"^[\u4e00-\u9fffA-Za-z0-9][\u4e00-\u9fffA-Za-z0-9._\- ]{0,79}$")
_FILE_MAX_BYTES = 100 * 1024   # 单文件上限 100KB（纯文本）
_READ_MAX_CHARS = 10000        # 单次读回给模型的上限
_LIST_LIMIT = 50               # 列表最多展示条数


def _user_file_dir(user: User):
    return Path(settings.files_root) / str(user.id)


def _safe_file_path(user: User, name: str):
    """校验文件名防路径穿越：中文/字母/数字开头，可带 . - _ 与空格，禁止路径符号"""
    name = name.strip()
    if not _FILE_NAME_RE.match(name):
        return None, (f"文件名「{name[:40]}」不合法：只能用中文/字母/数字开头，"
                      "可带 . - _ 和空格，不要带 / \\ : 等路径符号。")
    d = _user_file_dir(user)
    p = d / name
    try:
        if not p.resolve().is_relative_to(d.resolve()):
            return None, "文件名不合法。"
    except OSError:
        return None, "文件柜目录异常，无法访问。"
    return p, ""


async def _save_file(args: dict, user: User, db: Session) -> str:
    name = str(args.get("name") or "")
    content = args.get("content")
    if not name.strip():
        raise ToolError("缺少必需参数：name")
    if content is None or not str(content).strip():
        raise ToolError("缺少必需参数：content")
    path, err = _safe_file_path(user, name)
    if path is None:
        return err
    text = str(content)
    size = len(text.encode("utf-8"))
    if size > _FILE_MAX_BYTES:
        return f"内容太长（约 {size // 1024}KB，上限 {_FILE_MAX_BYTES // 1024}KB）。请精简后重存，或拆成几个文件。"
    existed = path.is_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    except PermissionError:
        return ("文件柜目录没有写入权限。请在服务器上执行一次："
                f"sudo mkdir -p {settings.files_root} && sudo chown zhr {settings.files_root}")
    except OSError as e:
        return f"文件写入失败：{e}"
    return f"{'已更新' if existed else '已保存'}文件《{path.name}》（{size / 1024:.1f}KB）。之后说'读一下{path.name}'就能取出来。"


async def _read_file(args: dict, user: User, db: Session) -> str:
    name = str(args.get("name") or "")
    if not name.strip():
        raise ToolError("缺少必需参数：name")
    path, err = _safe_file_path(user, name)
    if path is None:
        return err
    if not path.is_file():
        return f"文件柜里没有《{path.name}》。可以先 list_files 看看存了哪些文件。"
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        return f"文件读取失败：{e}"
    total = len(text)
    if total > _READ_MAX_CHARS:
        text = text[:_READ_MAX_CHARS] + f"\n\n（文件共 {total} 字符，已只读前 {_READ_MAX_CHARS} 个）"
    return f"《{path.name}》内容如下：\n\n{text}"


async def _list_files(args: dict, user: User, db: Session) -> str:
    d = _user_file_dir(user)
    try:
        entries = sorted(d.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True) if d.is_dir() else []
    except PermissionError:
        return f"文件柜目录没有访问权限（{d}）。请在服务器上检查目录归属（chown zhr）。"
    except OSError:
        entries = []
    lines = []
    for x in entries:
        if len(lines) == _LIST_LIMIT:
            lines.append(f"（仅展示最近 {len(lines)} 个）")
            break
        try:
            if not x.is_file():
                continue
            st = x.stat()
            when = datetime.fromtimestamp(st.st_mtime).strftime("%m-%d %H:%M")
            lines.append(f"· {x.name}（{st.st_size / 1024:.1f}KB，{when} 改动）")
        except OSError:
            continue
    if not lines:
        return "文件柜还是空的。主人说'帮我存个文件'就能把内容存进来，之后随时让我读出来。"
    return "文件柜里的文件：\n" + "\n".join(lines)


async def _browse_url(args: dict, user: User, db: Session) -> str:
    url = str(args.get("url") or "").strip()
    if not url:
        raise ToolError("缺少必需参数：url")
    return await browse(url)


# ── 技能库（流程说明书：纯 markdown，随代码部署）────────
SKILLS_DIR = Path(__file__).parent / "skills"


async def _list_skills(args: dict, user: User, db: Session) -> str:
    files = sorted(SKILLS_DIR.glob("*.md"))
    if not files:
        return "技能库还是空的。"
    lines = []
    for p in files:
        try:
            head = p.read_text(encoding="utf-8").splitlines()
            title = next((l.lstrip("# ").strip() for l in head if l.strip()), p.stem)
        except OSError:
            title = p.stem
        lines.append(f"· {p.stem}：{title}")
    return "可用技能（用 load_skill 读取后照步骤执行）：\n" + "\n".join(lines)


async def _load_skill(args: dict, user: User, db: Session) -> str:
    name = str(args.get("name") or "").strip().removesuffix(".md")
    if not re.fullmatch(r"[a-z0-9_]{1,40}", name):
        return "技能名不合法（小写字母/数字/下划线）。先 list_skills 看看有哪些可用。"
    p = SKILLS_DIR / f"{name}.md"
    if not p.is_file():
        return f"技能库里没有「{name}」。先 list_skills 看看有哪些可用。"
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as e:
        return f"技能读取失败：{e}"
    return f"技能【{name}】说明书如下，请严格照步骤执行：\n\n{text}"


async def _web_search(args: dict, user: User, db: Session) -> str:
    query = str(args.get("query") or "").strip()
    if not query:
        raise ToolError("缺少必需参数：query")
    if not settings.tavily_api_key:
        return "搜索还没配置：管理员需要在服务器 .env 里加 TAVILY_API_KEY（tavily.com 免费申请）后重启服务。"
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(
                "https://api.tavily.com/search",
                headers={"Authorization": f"Bearer {settings.tavily_api_key}"},
                json={"query": query, "max_results": 5, "include_answer": "basic"},
            )
            resp.raise_for_status()
            data = resp.json()
    except Exception as e:  # noqa: BLE001 —— 失败给模型可读原因，让它自愈
        return f"搜索服务暂时不可用（{e}）。请稍后再试，或基于已有知识回答并说明未联网核实。"
    lines = []
    if data.get("answer"):
        lines.append(f"摘要：{data['answer']}")
    for r in data.get("results", []):
        lines.append(f"· {r.get('title', '')} — {r.get('url', '')}\n  {str(r.get('content', ''))[:200]}")
    if not lines:
        return f"「{query}」没有搜到有效结果，换个关键词再试。"
    return "搜索「" + query + "」：\n" + "\n".join(lines)


# ── 工具执行入口 ──────────────────────────────────────

class ToolError(Exception):
    """工具层可预期错误（缺参数等）——消息原文回给模型，让它自行纠正"""


def _number_value(v: Any) -> float:
    """宽松取数值：模型可能给 15、"15" 或 15.5（V1 numberValue 的移植）"""
    if isinstance(v, bool):
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return 0.0
    return 0.0


async def run_tool(tool: AgentTool, arguments_json: str, user: User, db: Session) -> str:
    """带兜底的执行入口：任何异常都变成文本结果回给模型，不中断 ReAct 循环"""
    try:
        args = json.loads(arguments_json) if arguments_json.strip() else {}
        if not isinstance(args, dict):
            args = {}
        return await tool.execute(args, user, db)
    except ToolError as e:
        return f"工具执行失败：{e}"
    except Exception as e:  # noqa: BLE001 —— 故意宽捕获：错误文本回填让模型自愈
        return f"工具执行失败：{e}"
