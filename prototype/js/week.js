// 周数计算与单双周判定（纯逻辑，无 DOM 依赖）

export const MS_PER_DAY = 86400000;

export function startOfDay(dt) {
  return new Date(dt.getFullYear(), dt.getMonth(), dt.getDate());
}

export function formatDate(dt) {
  const p = (n) => String(n).padStart(2, '0');
  return `${dt.getFullYear()}-${p(dt.getMonth() + 1)}-${p(dt.getDate())}`;
}

/** 学期开始日 'YYYY-MM-DD' 到 now 是第几周；开学前/无开始日返回 null */
export function currentWeekNumber(startDateStr, now = new Date()) {
  const parts = String(startDateStr || '').split('-').map(Number);
  if (parts.length !== 3 || parts.some((n) => !Number.isFinite(n))) return null;
  const [y, m, d] = parts;
  const start = new Date(y, m - 1, d);
  const diffDays = Math.floor((startOfDay(now) - start) / MS_PER_DAY);
  return diffDays < 0 ? null : Math.floor(diffDays / 7) + 1;
}

export function weekParityOf(weekNumber) {
  return weekNumber % 2 === 1 ? 'single' : 'double';
}
