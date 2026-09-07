import assert from 'node:assert';
import { guessMapping, mapRows, normalizeDayOfWeek, normalizeParity, normalizeWeek } from '../js/mapping.js';

const header = ['课程名称', '教师', '地点', '星期', '开始时间', '结束时间', '起始周', '结束周', '单双周'];
const fm = guessMapping(header);
assert.equal(fm.name, 0);
assert.equal(fm.teacher, 1);
assert.equal(fm.location, 2);
assert.equal(fm.dayOfWeek, 3);
assert.equal(fm.startTime, 4);
assert.equal(fm.endTime, 5);
assert.equal(fm.startWeek, 6);
assert.equal(fm.endWeek, 7);
assert.equal(fm.weekParity, 8);

// 表头完全对不上时返回 -1
assert.equal(guessMapping(['A', 'B', 'C']).name, -1);

assert.equal(normalizeDayOfWeek('1'), 1);
assert.equal(normalizeDayOfWeek('星期一'), 1);
assert.equal(normalizeDayOfWeek('周三'), 3);
assert.equal(normalizeDayOfWeek('日'), 7);
assert.equal(normalizeDayOfWeek('星期天'), 7);
assert.equal(normalizeDayOfWeek('x'), null);

assert.equal(normalizeParity('单'), 'single');
assert.equal(normalizeParity('双'), 'double');
assert.equal(normalizeParity('单双'), 'both');
assert.equal(normalizeParity('每周'), 'both');
assert.equal(normalizeWeek('3'), 3);
assert.equal(normalizeWeek('abc'), null);

const rows = [
  header,
  ['高等数学', '张老师', '教1-201', '一', '08:00', '09:40', 1, 16, '单双'],
  ['', '李老师', '外语楼', '二', '10:00', '11:40', 1, 16, '单'],       // 名称空 → 计入 errors
  ['大学英语', '', '', '三', '9:00', '9:59', 2, 3, '双'],
  ['坏时间课', '', '', '四', '99:00', '10:00', 1, 16, '单'],           // 时间非法 → errors
];
const { courses, errors } = mapRows(rows, fm);
assert.equal(courses.length, 2, '两条合法课程');
assert.equal(courses[0].name, '高等数学');
assert.equal(courses[0].dayOfWeek, 1);
assert.equal(courses[0].weekParity, 'both');
assert.equal(courses[1].startWeek, 2);
assert.equal(errors.length, 2, '两条错误行被报告');
assert.equal(errors[0].row, 3, '错误行号（含表头）');
console.log('✔ mapping.test');
