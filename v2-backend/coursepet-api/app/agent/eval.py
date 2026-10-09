# MARK: - Agent 评测（模式 10：评估观测）
# 设计三原则：
#   1. 确定性：评测跑在专用账号 __eval__ 上，每轮跑前清空并重建 fixture 数据
#      （今天有什么课/作业/账单/步数都是已知值），断言才能硬校验"数据正确流到回答里"
#   2. 两类断言：
#      expect_tools  ⊆ 实际调用集合 —— 验证 ReAct 选对了工具（且允许模型自主多调）
#      expect_any    任一关键词命中回答 —— 验证答案内容正确
#      expect_no_tools 断言一次工具都没调 —— 防止"闲聊也去查库"的过度调用
#   3. 温度 0.6 有随机性 → 关键词给多个候选（如 "20.5"/"20.50"），宁松勿误报；
#      每条用例的 note 记录它防的回归场景——测试集即文档
# 可靠性观测（本次扩展）：每条用例记录 duration_ms / llm_calls / llm_ms /
#   tokens_in / tokens_out（网关返回 usage 才有）——"我的 Agent 有评测门禁"
#   比"我做了 20 个页面"值钱得多。
# 评测是"改 prompt / 换模型"的回归门禁：分数掉了就说明改动伤到了某类场景。
import asyncio
import json
import secrets
import shutil
import time
from datetime import date, datetime, timedelta
from pathlib import Path

from sqlalchemy import delete, select

from ..config import settings
from ..database import SessionLocal
from ..models import AgentWrite, Course, CourseDoc, EvalRun, Homework, LedgerEntry, MemoryEntry, Parcel, PetTask, PetTaskResult, StudyPlan, User
from ..security import hash_password
from .embeddings import embed
from .engine import reset_history, send
from .memory_crypto import encrypt_memory

_EVAL_LOCK = asyncio.Lock()          # 评测涉及 fixture 重建，全局串行防互相污染
EVAL_USERNAME = "__eval__"           # 专用评测账号（不会出现在正常用户列表场景）
GATE_LINE = 85.0                     # 门禁线：分数低于它时 gate.passed=False，改动不许合入


# ── 测试集（37 条：工具全覆盖 + 宠物任务/记忆注入 + 复合/卡片/人设/拒答越界）──────────
CASES: list[dict] = [
    {"q": "今天有什么课",
     "expect_tools": ["get_today_schedule"], "expect_any": ["高数"],
     "note": "读类核心：课表数据正确性（单双周过滤已含在 fixture）"},
    {"q": "下一节是什么课",
     "expect_tools": ["get_next_class"], "expect_any": ["高数", "英语", "课"],
     "note": "时间感知：按当前时刻取下一节"},
    {"q": "我现在大几周了",
     "expect_any": ["4", "四"],
     "note": "周数计算探针：semester_start=今天-21天 应为第4周（若失败说明周数未进 system prompt/工具）"},
    {"q": "我有什么作业没做完",
     "expect_tools": ["get_pending_homeworks", "show_card"],
     "note": "作业列表数据正确性；模式11后数据在卡片里渲染，文字不重复罗列，只断言工具链"},
    {"q": "这个月花了多少钱",
     "expect_tools": ["get_month_expense"], "expect_any": ["20.5", "20.50"],
     "note": "聚合计算：12.5+8.0=20.5 必须算对"},
    {"q": "我今天走了多少步",
     "expect_tools": ["get_step_count"], "expect_any": ["6666", "6,666"],
     "note": "直读值：防止模型编步数（兼容千分位格式）"},
    {"q": "今天天气怎么样",
     "expect_tools": ["get_weather"],
     "note": "外部 API 工具：只断言会调（内容随天气变，不做关键词断言）"},
    {"q": "明天出门要带伞吗",
     "expect_tools": ["get_weather"], "expect_any": ["伞", "雨", "没", "不"],
     "note": "伞类问题的意图识别：应走天气工具而不是编答案"},
    {"q": "帮我记一笔：奶茶 12 元",
     "expect_tools": ["add_ledger_entry"], "expect_any": ["记上", "卡", "点"],
     "note": "写类走确认卡：工具弹卡不落库，回答应提醒点「记上」且不复述卡片内容"},
    {"q": "高数的作业我都交完了",
     "expect_tools": ["mark_homework_done"],
     "expect_any": ["确认", "哪一条", "哪条", "哪项", "哪个", "哪一个", "哪份", "具体", "告诉"],
     "note": "模式 9 人机协同：两条高数作业都命中时不许替用户做主，必须先列出确认（措辞多样故宽词表）"},
    {"q": "实验报告交了",
     "expect_tools": ["mark_homework_done"], "expect_any": ["完成", "✅", "搞定", "好"],
     "note": "唯一命中时直接标记完成"},
    {"q": "帮我记一下，10月2号要交高数实验报告",
     "expect_tools": ["add_homework"],
     "expect_any": ["记上", "卡", "点", "记好", "记下", "帮你"],
     "note": "写类走确认卡：DDL 语义解析（用绝对日期避免模型对相对时间反问澄清）"},
    {"q": "帮我加一门课：周五 14:00-15:40 大学英语听力",
     "expect_tools": ["modify_schedule"],
     "expect_any": ["记上", "卡", "点"],
     "note": "课表写操作走确认卡（modify_schedule 出卡不落库，回答应提醒点「记上」）"},
    {"q": "帮我记个快递：您有包裹在菜鸟驿站，取件码 8-2-3061，请及时领取",
     "expect_tools": ["add_parcel_from_sms"], "expect_any": ["3061", "记"],
     "note": "写类：短信原文解析取件码"},
    {"q": "帮我记个快递：顺丰到件，单号SF3100000000002，取件码3-2-5088，已放近邻宝",
     "expect_tools": ["add_parcel_from_sms"], "expect_any": ["5088", "记"],
     "note": "写类：带单号短信（单号入库供后续物流追踪）"},
    {"q": "刚记的那个快递记错了，撤了吧",
     "expect_tools": ["undo_last_write"], "expect_any": ["撤", "撤销"],
     "note": "写撤销：上一条用例刚写了快递，undo 应回滚它（依赖用例顺序）"},
    {"q": "这个月花了多少？另外我还有哪些事没做完？",
     "expect_tools": ["get_month_expense", "get_pending_homeworks"],
     "note": "复合调用：一句话触发多个工具（ReAct 多跳能力）"},
    {"q": "你叫什么名字呀",
     "expect_no_tools": True, "expect_any": ["小狼", "宠物", "管家"],
     "note": "人设：不该调任何工具，回答带身份感"},
    {"q": "1加1等于几",
     "expect_no_tools": True, "expect_any": ["2", "二", "两"],
     "note": "反过度调用：常识问答不许查库"},
    {"q": "你能帮我做哪些事呀",
     "expect_no_tools": True, "expect_any": ["课表", "作业", "账", "天气", "快递"],
     "note": "能力介绍：纯回答，不该触发工具"},
    {"q": "帮我记一笔买午饭的钱",
     "expect_any": ["多少", "几元", "几块", "金额", "告诉我"],
     "note": "模式 9：写操作关键信息缺失（没说金额）应追问而不是猜——只断言追问话术"},
    {"q": "帮我做一个从10月1号到10月2号的高数期末复习计划",
     "expect_tools": ["create_study_plan"], "expect_any": ["计划", "复习"],
     "note": "模式 8 规划：目标拆解落库（用绝对日期避免模型对'明天'反问澄清）"},
    {"q": "我的复习计划进度怎么样",
     "expect_tools": ["check_study_plan"], "expect_any": ["计划", "任务", "复习"],
     "note": "模式 8：进度对照（fixture 预置了进行中计划）"},
    {"q": "把这段存进资料库：泰勒公式的核心思想是用多项式逼近函数",
     "expect_tools": ["add_course_material"], "expect_any": ["存", "资料库", "收"],
     "note": "RAG 写入"},
    {"q": "我的笔记里泰勒公式讲了什么",
     "expect_tools": ["search_course_materials"], "expect_any": ["泰勒", "逼近", "多项式"],
     "note": "RAG 读取：fixture 预置的笔记内容必须流到回答里"},
    {"q": "我的快递到哪了",
     "expect_tools": ["get_parcel_status"],
     "note": "外部 API 工具：fixture 单号是假的，只断言会调（查不到也是正确降级）"},
    {"q": "把我未完成的作业做成卡片",
     "expect_tools": ["get_pending_homeworks", "show_card"],
     "note": "模式 11：明确要卡片时应先查数据再调 show_card"},
    {"q": "今天的课表做成卡片",
     "expect_tools": ["get_today_schedule", "show_card"],
     "note": "模式 11：课表卡"},
    {"q": "本月账单做成卡片看看",
     "expect_tools": ["get_month_expense", "show_card"],
     "note": "模式 11：账单卡"},
    {"q": "打车回学校花了20块",
     "expect_tools": ["add_ledger_entry"], "expect_any": ["记上", "卡", "点"],
     "note": "分类归一：打车→交通（守则 3）；确认卡模式下断言出卡提醒话术"},
    {"q": "这个月餐饮花了多少",
     "expect_tools": ["get_month_expense"], "expect_any": ["餐饮", "20.5"],
     "note": "分类聚合问答"},
    {"q": "你是什么动物呀",
     "expect_no_tools": True, "expect_any": ["狼", "宠物", "小狼"],
     "note": "人设一致性的第二探针"},
    {"q": "每天早上8点帮我看一下今天的课表和未完成作业，建个定时任务",
     "expect_tools": ["create_task"], "expect_any": ["定时任务", "每天", "08:00", "8:00"],
     "note": "异步任务引擎：'定期做事'应建任务（到点自动执行）而不是只当场查一次；只断言创建确认"},
    {"q": "帮我把这段话存成文件 lesson1.md：高数第三章重点是泰勒公式",
     "expect_tools": ["save_file"], "expect_any": ["lesson1", "存"],
     "note": "Muse 式文件柜：写文件（读/列表复用同一目录机制，不重复铺用例）"},
    {"q": "以后每周一早上8点给我发个本周规划吧",
     "expect_tools": ["create_pet_task"], "expect_any": ["周一", "08:00", "8:00", "每周"],
     "note": "宠物任务：'定期主动发消息'应建 create_pet_task（推送消息）而不是 create_task（跑工具），守则 10 的分工辨析"},
    {"q": "我让你主动发消息的任务有哪些",
     "expect_tools": ["list_pet_tasks"], "expect_any": ["周一", "规划"],
     "note": "宠物任务查询：上一条刚建的「本周规划」应出现在列表里（依赖用例顺序）"},
    {"q": "那个每周规划的任务停掉吧，先别发了",
     "expect_tools": ["remove_pet_task"], "expect_any": ["停", "不再", "好"],
     "note": "宠物任务停用：模型应自己 list 拿编号再 remove（ReAct 多跳）；依赖前两条用例"},
    {"q": "我吃花生酱行吗",
     "expect_no_tools": True, "expect_any": ["过敏", "疹子", "不吃", "别吃", "不行", "别", "注意"],
     "note": "记忆注入：fixture 预置的加密记忆「花生过敏」应流进 system prompt 并被自然引用，无需调工具"},
]


def _get_or_create_eval_user(db) -> User:
    user = db.scalar(select(User).where(User.username == EVAL_USERNAME))
    if user is None:
        user = User(username=EVAL_USERNAME,
                    password_hash=hash_password(secrets.token_hex(16)),
                    pet_name="小狼")
        db.add(user)
        db.commit()
        db.refresh(user)
    return user


def _rebuild_fixture(db, user: User) -> None:
    """清空并重建评测账号的已知数据（评测确定性的根基）"""
    today = date.today()
    now = datetime.now()
    for table in (Course, Homework, LedgerEntry, AgentWrite, MemoryEntry, StudyPlan, CourseDoc, Parcel, PetTask, PetTaskResult):
        db.execute(delete(table).where(table.user_id == user.id))
    # 文件柜：清空评测账号目录（save_file 用例的确定性）
    shutil.rmtree(Path(settings.files_root) / str(user.id), ignore_errors=True)
    # 课表：两节今天的课（早八高数 / 下午英语）+ 一节今天的单周课（第4周是双周，必须被过滤）
    db.add_all([
        Course(user_id=user.id, name="高数", teacher="王老师", location="A101",
               day_of_week=today.isoweekday(), start_time="08:00", end_time="09:40"),
        Course(user_id=user.id, name="英语", teacher="李老师", location="B202",
               day_of_week=today.isoweekday(), start_time="14:00", end_time="15:40"),
        Course(user_id=user.id, name="单周专属体育", teacher="", location="操场",
               day_of_week=today.isoweekday(), start_time="18:00", end_time="19:40",
               week_parity="single"),
    ])
    # 作业：三条未完成（两条高数 → 多条命中确认用例；一条英语做干扰项）
    db.add_all([
        Homework(user_id=user.id, title="高数实验报告",
                 due_date=now + timedelta(days=3), is_done=False),
        Homework(user_id=user.id, title="高数第三章习题",
                 due_date=now + timedelta(days=5), is_done=False),
        Homework(user_id=user.id, title="英语听力作业",
                 due_date=now + timedelta(days=1), is_done=False),
    ])
    # 账单：12.5 + 8.0 = 20.5
    db.add_all([
        LedgerEntry(user_id=user.id, amount=12.5, category="餐饮", note="奶茶"),
        LedgerEntry(user_id=user.id, amount=8.0, category="餐饮", note="早饭"),
    ])
    # 学期开始 = 今天 - 21 天 → 本周是第 4 周
    user.semester_start_date = today - timedelta(days=21)
    # 步数 6666；坐标北京（天气工具走 Open-Meteo 真实调用）
    user.today_steps = 6666
    user.steps_date = today
    user.latitude, user.longitude = 39.909, 116.397
    # 复习计划（模式 8）：进行中 + 两条"复习计划"作业（一条今天/一条昨天逾期）
    db.add(StudyPlan(user_id=user.id, goal="高数期末复习",
                     plan_json=json.dumps([
                         {"date": (today - timedelta(days=1)).isoformat(), "task": "复习：极限计算"},
                         {"date": today.isoformat(), "task": "复习：泰勒公式"},
                     ], ensure_ascii=False), is_active=True))
    db.add_all([
        Homework(user_id=user.id, title="复习：极限计算", course_name="复习计划",
                 due_date=datetime.combine(today - timedelta(days=1), datetime.min.time()).replace(hour=22), is_done=False),
        Homework(user_id=user.id, title="复习：泰勒公式", course_name="复习计划",
                 due_date=datetime.combine(today, datetime.min.time()).replace(hour=22), is_done=False),
    ])
    # 课程资料（RAG）：预置一条泰勒公式笔记，检索用例的关键词断言依赖它
    doc_content = ("泰勒公式：用函数在某点的导数信息构造多项式来逼近函数，核心是逼近思想；"
                   "误差通过拉格朗日余项估计。常用展开：e^x、sin x、cos x、ln(1+x)。")
    db.add(CourseDoc(user_id=user.id, title="高数笔记·泰勒公式",
                     content=doc_content, vector=embed(doc_content)))
    # 快递：一条带顺丰单号的待取件（get_parcel_status 用例的数据源）
    db.add(Parcel(user_id=user.id, code="3-2-5088", station="菜鸟驿站",
                  tracking_no="SF3100000000001", is_picked=False))
    # 长期记忆：一条加密的过敏事实（记忆注入用例的数据源——密文落库，注入时解密）
    db.add(MemoryEntry(user_id=user.id, kind="fact", importance=5,
                       content=encrypt_memory(user.id, "主人对花生过敏，吃花生会起疹子")))
    db.commit()


def _judge(case: dict, tools_used: list[str],
           answer: str, has_final_answer: bool) -> tuple[bool, str | None]:
    if not has_final_answer:
        return False, "没有最终回答（引擎报错或超出轮数）"
    for t in case.get("expect_tools", []):
        if t not in tools_used:
            return False, f"未调用工具 {t}（实际：{tools_used or '无'}）"
    if case.get("expect_no_tools") and tools_used:
        return False, f"不应调用工具却调了：{tools_used}"
    kws = case.get("expect_any")
    if kws and not any(k in answer for k in kws):
        return False, f"回答缺少关键词 {kws}"
    return True, None


async def run_eval_suite(trigger_user: User) -> dict:
    """跑全量测试集 → 逐条判定 → 存档 EvalRun → 返回报告（含门禁与观测数据）"""
    async with _EVAL_LOCK:
        db = SessionLocal()
        try:
            eval_user = _get_or_create_eval_user(db)
            _rebuild_fixture(db, eval_user)
        finally:
            db.close()

        started = time.monotonic()
        results: list[dict] = []
        total_llm_ms = total_llm_calls = 0
        total_tok_in = total_tok_out = 0
        for case in CASES:
            tools_used: list[str] = []
            stats: dict = {}
            t0 = time.monotonic()
            reset_history(eval_user.id)      # 每条用例独立上下文，互不串扰
            display = await send(eval_user, case["q"], tools_used=tools_used, stats=stats)
            answer = " ".join(m.text for m in display if m.kind in ("assistant", "error"))
            has_final = any(m.kind == "assistant" for m in display)
            ok, reason = _judge(case, tools_used, answer, has_final)
            tok_in = stats.get("prompt_tokens", 0)
            tok_out = stats.get("completion_tokens", 0)
            total_llm_ms += stats.get("llm_ms", 0)
            total_llm_calls += stats.get("llm_calls", 0)
            total_tok_in += tok_in
            total_tok_out += tok_out
            results.append({
                "question": case["q"],
                "pass": ok,
                "tools": tools_used,
                "answer": answer[:120],
                "fail_reason": reason,
                "note": case.get("note", ""),
                # 可靠性观测：每条用例的延迟与 token 明细
                "duration_ms": int((time.monotonic() - t0) * 1000),
                "llm_calls": stats.get("llm_calls", 0),
                "llm_ms": stats.get("llm_ms", 0),
                "tokens_in": tok_in,
                "tokens_out": tok_out,
            })

        duration_ms = int((time.monotonic() - started) * 1000)
        passed = sum(1 for r in results if r["pass"])
        score = round(passed / len(CASES) * 100, 1)

        # 存档：分数时间曲线 = 每次改动的回归证据。
        # 明细压缩存储（q/p/r 三键），answers/观测明细只在接口响应里给全——
        # 32 条用例的完整明细超出一列 4000 字符，压不下的部分截断无碍。
        compact = [{"q": r["question"], "p": r["pass"],
                    **({"r": r["fail_reason"]} if r["fail_reason"] else {})}
                   for r in results]
        db = SessionLocal()
        try:
            db.add(EvalRun(
                user_id=trigger_user.id,
                model=settings.llm_model,
                total=len(CASES),
                passed=passed,
                duration_ms=duration_ms,
                detail=json.dumps(compact, ensure_ascii=False)[:3900],
            ))
            db.commit()
        finally:
            db.close()

        return {
            "total": len(CASES),
            "passed": passed,
            "score": score,
            "gate": {"line": GATE_LINE, "passed": score >= GATE_LINE},
            "model": settings.llm_model,
            "duration_ms": duration_ms,
            # 全局观测：LLM 累计耗时/调用次数/token（usage 缺失时为 0）
            "llm_ms": total_llm_ms,
            "llm_calls": total_llm_calls,
            "tokens_in": total_tok_in,
            "tokens_out": total_tok_out,
            "results": results,
        }
