// Excel 行数据 → 课程对象：表头自动猜测 + 手动映射 + 逐行校验（纯逻辑）
import { createCourse, timeToMinutes } from './schedule.js';

const KEYWORDS = {
  name: ['课程', '名称', '课名'],
  teacher: ['教师', '老师', '授课'],
  location: ['地点', '教室', '位置'],
  dayOfWeek: ['星期', '周几'],
  startTime: ['开始时间', '上课时间', '开始'],
  endTime: ['结束时间', '下课时间', '结束'],
  startWeek: ['起始周', '开始周', '起始'],
  endWeek: ['结束周', '终止周', '截止'],
  weekParity: ['单双', '周型', '周次类型'],
};

/** 按关键字猜测表头列，匹配不到为 -1 */
export function guessMapping(headerRow) {
  const fm = {};
  for (const [field, kws] of Object.entries(KEYWORDS)) {
    fm[field] = headerRow.findIndex((h) => kws.some((k) => String(h).includes(k)));
  }
  return fm;
}

export function normalizeDayOfWeek(v) {
  const s = String(v ?? '').trim();
  if (/^[1-7]$/.test(s)) return Number(s);
  const map = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7 };
  for (const [ch, n] of Object.entries(map)) {
    if (s.includes(ch)) return n;
  }
  return null;
}

export function normalizeParity(v) {
  const s = String(v ?? '');
  if (s.includes('双') && s.includes('单')) return 'both';
  if (s.includes('双')) return 'double';
  if (s.includes('单')) return 'single';
  return 'both';
}

export function normalizeWeek(v) {
  const n = parseInt(String(v), 10);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * rows: SheetJS sheet_to_json(ws, {header:1}) 的输出（首行为表头）
 * fm: {name, teacher, location, dayOfWeek, startTime, endTime, startWeek, endWeek, weekParity} → 列号（-1 缺省）
 * 返回 {courses, errors:[{row, reason}]}，空行跳过，坏行不阻断整体
 */
export function mapRows(rows, fm) {
  const courses = [], errors = [];
  const col = (row, field) => (fm[field] != null && fm[field] >= 0 ? row[fm[field]] : undefined);
  for (let i = 1; i < rows.length; i++) {
    const row = rows[i], rowNo = i + 1;
    if (!row || row.every((c) => c === undefined || c === null || String(c).trim() === '')) continue;
    const name = String(col(row, 'name') ?? '').trim();
    const dow = normalizeDayOfWeek(col(row, 'dayOfWeek'));
    const startTime = String(col(row, 'startTime') ?? '').trim();
    const endTime = String(col(row, 'endTime') ?? '').trim();
    if (!name) { errors.push({ row: rowNo, reason: '缺少课程名称' }); continue; }
    if (!dow) { errors.push({ row: rowNo, reason: `星期几无法识别（${String(col(row, 'dayOfWeek') ?? '').trim() || '空'}）` }); continue; }
    if (!timeToMinutes(startTime)) { errors.push({ row: rowNo, reason: '开始时间格式不对（应为 HH:mm）' }); continue; }
    if (!timeToMinutes(endTime)) { errors.push({ row: rowNo, reason: '结束时间格式不对（应为 HH:mm）' }); continue; }
    const startWeek = normalizeWeek(col(row, 'startWeek')) ?? 1;
    const endWeek = normalizeWeek(col(row, 'endWeek')) ?? 20;
    if (endWeek < startWeek) { errors.push({ row: rowNo, reason: '结束周小于起始周' }); continue; }
    courses.push(createCourse({
      name,
      teacher: String(col(row, 'teacher') ?? '').trim(),
      location: String(col(row, 'location') ?? '').trim(),
      dayOfWeek: dow, startTime, endTime, startWeek, endWeek,
      weekParity: normalizeParity(col(row, 'weekParity')),
    }));
  }
  return { courses, errors };
}
