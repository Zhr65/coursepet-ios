import assert from 'node:assert';
import { currentWeekNumber, weekParityOf, startOfDay, formatDate, MS_PER_DAY } from '../js/week.js';

// 以 2026-09-07（周一）为学期开始日
const d = (s) => new Date(s + 'T12:00:00');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-07')), 1, '开学当天=第1周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-13')), 1, '第6天仍是第1周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-14')), 2, '第7天进入第2周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-20')), 2, '第13天仍是第2周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-21')), 3, '第14天进入第3周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-01')), null, '开学前返回 null');
assert.equal(currentWeekNumber('', new Date()), null, '无开始日返回 null');
assert.equal(weekParityOf(1), 'single');
assert.equal(weekParityOf(2), 'double');
assert.equal(weekParityOf(3), 'single');
assert.equal(formatDate(new Date(2026, 8, 7)), '2026-09-07');
const so = startOfDay(new Date(2026, 8, 7, 23, 59, 59));
assert.equal(so.getHours(), 0, 'startOfDay 归零时分秒');
assert.equal(MS_PER_DAY, 86400000);
console.log('✔ week.test');
