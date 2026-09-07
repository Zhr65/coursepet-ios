// 课程模型 / 周过滤 / 当前与下一节 / 倒计时（纯逻辑）
import { weekParityOf } from './week.js';

export const COURSE_COLORS = ['#FFD1C4', '#C4E3FF', '#C9F2D0', '#FFF3BF', '#E5D4FF', '#FFE0B8', '#CBEFE7'];

export function timeToMinutes(t) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(t).trim());
  if (!m) return null;
  const h = Number(m[1]), min = Number(m[2]);
  return h > 23 || min > 59 ? null : h * 60 + min;
}

export function isValidTime(t) { return timeToMinutes(t) !== null; }

export function createCourse(o) {
  return {
    id: o.id ?? (String(Date.now()) + Math.random().toString(36).slice(2, 7)),
    name: o.name,
    teacher: o.teacher || '',
    location: o.location || '',
    dayOfWeek: o.dayOfWeek,           // 1=周一 … 7=周日
    startTime: o.startTime,            // 'HH:mm'
    endTime: o.endTime,
    startWeek: o.startWeek ?? 1,
    endWeek: o.endWeek ?? 20,
    weekParity: o.weekParity || 'both', // single|double|both
    color: o.color || COURSE_COLORS[((o.dayOfWeek || 1) - 1) % COURSE_COLORS.length],
  };
}

export function coursesForWeek(courses, weekNumber) {
  const parity = weekParityOf(weekNumber);
  return courses.filter((c) =>
    c.startWeek <= weekNumber && c.endWeek >= weekNumber &&
    (c.weekParity === 'both' || c.weekParity === parity));
}

export function coursesForDay(courses, dayOfWeek) {
  return courses.filter((c) => c.dayOfWeek === dayOfWeek)
    .sort((a, b) => timeToMinutes(a.startTime) - timeToMinutes(b.startTime));
}

/** 当天日号换算：JS getDay() 0=周日 → 1=周一…7=周日 */
function todayDow(now) { const g = now.getDay(); return g === 0 ? 7 : g; }

export function currentAndNext(courses, now) {
  const dow = todayDow(now);
  const curMin = now.getHours() * 60 + now.getMinutes();
  const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let current = null, next = null;
  for (const c of courses) {
    if (c.dayOfWeek !== dow) continue;
    const s = timeToMinutes(c.startTime), e = timeToMinutes(c.endTime);
    const crossMidnight = e <= s; // 跨午夜课
    if (s <= curMin && (crossMidnight || curMin < e)) {
      if (!current || s >= timeToMinutes(current.startTime)) current = c;
    }
    if (curMin < s && (!next || s < timeToMinutes(next.startTime))) next = c;
  }
  return {
    current,
    next: next
      ? { ...next, startDate: new Date(midnight.getTime() + timeToMinutes(next.startTime) * 60000) }
      : null,
  };
}

/** 倒计时文本 HH:MM:SS，已过则 00:00:00 */
export function countdownText(target, now = new Date()) {
  let diff = Math.max(0, target - now);
  const h = Math.floor(diff / 3600000); diff -= h * 3600000;
  const m = Math.floor(diff / 60000); diff -= m * 60000;
  const s = Math.floor(diff / 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(h)}:${p(m)}:${p(s)}`;
}
