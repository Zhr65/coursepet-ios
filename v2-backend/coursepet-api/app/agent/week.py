# MARK: - 周数计算（翻译自 WeekMath.swift，逻辑与 Web prototype/js/week.js 一致）
# 规则：开学日当天记为第 1 周的第一天，每 7 天 +1 周；开学前返回 None。
from datetime import date, timedelta


def current_week_number(start: date | None, now: date | None = None) -> int | None:
    """学期开始日到今天是第几周；开学前 / 未设置返回 None"""
    if start is None:
        return None
    today = now or date.today()
    days = (today - start).days
    return days // 7 + 1 if days >= 0 else None


def week_parity_text(week: int) -> str:
    """单双周判定：奇数→单周，偶数→双周"""
    return "单周" if week % 2 == 1 else "双周"


def week_dates(week: int, start: date) -> list[date]:
    """第 week 周的 7 个日期（周一在前）——预留：课表视图可用"""
    monday = start + timedelta(days=(week - 1) * 7)
    return [monday + timedelta(days=i) for i in range(7)]
