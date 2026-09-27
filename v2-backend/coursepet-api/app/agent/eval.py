# MARK: - Agent 评测（模式 10：评估观测）
# 设计三原则：
#   1. 确定性：评测跑在专用账号 __eval__ 上，每轮跑前清空并重建 fixture 数据
#      （今天有什么课/作业/账单/步数都是已知值），断言才能硬校验"数据正确流到回答里"
#   2. 两类断言：
#      expect_tools  ⊆ 实际调用集合 —— 验证 ReAct 选对了工具（且允许模型自主多调）
#      expect_any    任一关键词命中回答 —— 验证答案内容正确
#   3. 温度 0.6 有随机性 → 关键词给多个候选（如 "20.5"/"20.50"），宁松勿误报；
#      每条用例的 note 记录它防的回归场景——测试集即文档
# 评测是"改 prompt / 换模型"的回归门禁：分数掉了就说明改动伤到了某类场景。
import asyncio
import json
import secrets
import time
from datetime import date, datetime, timedelta

from sqlalchemy import delete, select

from ..config import settings
from ..database import SessionLocal
from ..models import AgentWrite, Course, CourseDoc, EvalRun, Homework, LedgerEntry, Memory, StudyPlan, User
from ..security import hash_password
from .engine import reset_history, send

_EVAL_LOCK = asyncio.Lock()          # 评测涉及 fixture 重建，全局串行防互相污染
EVAL_USERNAME = "__eval__"           # 专用评测账号（不会出现在正常用户列表场景）


# ── 测试集（12 条：9 个工具全覆盖 + 复合调用 + 人设探测）──────────
CASES: list[dict] = [
    {"q": "今天有什么课",
     "expect_tools": ["get_today_schedule"], "expect_any": ["高数"],
     "note": "读类核心：课表数据正确性"},
    {"q": "下一节是什么课",
     "expect_tools": ["get_next_class"], "expect_any": ["高数", "英语", "课"],
     "note": "时间感知：按当前时刻取下一节"},
    {"q": "我现在大几周了",
     "expect_any": ["4", "四"],
     "note": "周数计算探针：semester_start=今天-21天 应为第4周（若失败说明周数未进 system prompt/工具）"},
    {"q": "我有什么作业没做完",
     "expect_tools": ["get_pending_homeworks"], "expect_any": ["高数"],
     "note": "作业列表数据正确性"},
    {"q": "这个月花了多少钱",
     "expect_tools": ["get_month_expense"], "expect_any": ["20.5", "20.50"],
     "note": "聚合计算：12.5+8.0=20.5 必须算对"},
    {"q": "我今天走了多少步",
     "expect_tools": ["get_step_count"], "expect_any": ["6666"],
     "note": "直读值：防止模型编步数"},
    {"q": "今天天气怎么样",
     "expect_tools": ["get_weather"],
     "note": "外部 API 工具：只断言会调（内容随天气变，不做关键词断言）"},
    {"q": "帮我记一笔：奶茶 12 元",
     "expect_tools": ["add_ledger_entry"], "expect_any": ["记", "12"],
     "note": "写类：自然语言→结构化记账"},
    {"q": "帮我记一下，周五要交高数实验报告",
     "expect_tools": ["add_homework"],
     "expect_any": ["实验报告", "周五", "记好", "记下", "好哒", "搞定", "帮你"],
     "note": "写类：DDL 语义解析（确认话术多样，关键词放宽防误报）"},
    {"q": "帮我记个快递：您有包裹在菜鸟驿站，取件码 8-2-3061，请及时领取",
     "expect_tools": ["add_parcel_from_sms"], "expect_any": ["3061", "记"],
     "note": "写类：短信原文解析取件码"},
    {"q": "这个月花了多少？另外我还有哪些事没做完？",
     "expect_tools": ["get_month_expense", "get_pending_homeworks"],
     "note": "复合调用：一句话触发多个工具（ReAct 多跳能力）"},
    {"q": "你叫什么名字呀",
     "expect_any": ["小狼", "宠物", "管家"],
     "note": "人设：不该调任何工具，回答带身份感"},
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
    for table in (Course, Homework, LedgerEntry, AgentWrite, Memory, StudyPlan, CourseDoc):
        db.execute(delete(table).where(table.user_id == user.id))
    # 课表：两节今天的课（早八高数 / 下午英语）
    db.add_all([
        Course(user_id=user.id, name="高数", teacher="王老师", location="A101",
               day_of_week=today.isoweekday(), start_time="08:00", end_time="09:40"),
        Course(user_id=user.id, name="英语", teacher="李老师", location="B202",
               day_of_week=today.isoweekday(), start_time="14:00", end_time="15:40"),
    ])
    # 作业：一条未完成
    db.add(Homework(user_id=user.id, title="高数实验报告",
                    due_date=now + timedelta(days=3), is_done=False))
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
    db.commit()


def _judge(case: dict, tools_used: list[str],
           answer: str, has_final_answer: bool) -> tuple[bool, str | None]:
    if not has_final_answer:
        return False, "没有最终回答（引擎报错或超出轮数）"
    for t in case.get("expect_tools", []):
        if t not in tools_used:
            return False, f"未调用工具 {t}（实际：{tools_used or '无'}）"
    kws = case.get("expect_any")
    if kws and not any(k in answer for k in kws):
        return False, f"回答缺少关键词 {kws}"
    return True, None


async def run_eval_suite(trigger_user: User) -> dict:
    """跑全量测试集 → 逐条判定 → 存档 EvalRun → 返回报告"""
    async with _EVAL_LOCK:
        db = SessionLocal()
        try:
            eval_user = _get_or_create_eval_user(db)
            _rebuild_fixture(db, eval_user)
        finally:
            db.close()

        started = time.monotonic()
        results: list[dict] = []
        for case in CASES:
            tools_used: list[str] = []
            reset_history(eval_user.id)          # 每条用例独立上下文，互不串扰
            display = await send(eval_user, case["q"], tools_used=tools_used)
            answer = " ".join(m.text for m in display if m.kind in ("assistant", "error"))
            has_final = any(m.kind == "assistant" for m in display)
            ok, reason = _judge(case, tools_used, answer, has_final)
            results.append({
                "question": case["q"],
                "pass": ok,
                "tools": tools_used,
                "answer": answer[:120],
                "fail_reason": reason,
                "note": case.get("note", ""),
            })

        duration_ms = int((time.monotonic() - started) * 1000)
        passed = sum(1 for r in results if r["pass"])

        # 存档：分数时间曲线 = 每次改动的回归证据
        db = SessionLocal()
        try:
            db.add(EvalRun(
                user_id=trigger_user.id,
                model=settings.llm_model,
                total=len(CASES),
                passed=passed,
                duration_ms=duration_ms,
                detail=json.dumps(results, ensure_ascii=False)[:3900],
            ))
            db.commit()
        finally:
            db.close()

        return {
            "total": len(CASES),
            "passed": passed,
            "score": round(passed / len(CASES) * 100, 1),
            "model": settings.llm_model,
            "duration_ms": duration_ms,
            "results": results,
        }
