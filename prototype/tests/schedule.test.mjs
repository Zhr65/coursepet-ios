import assert from 'node:assert';
import { createCourse, coursesForWeek, coursesForDay, currentAndNext, countdownText, timeToMinutes, isValidTime } from '../js/schedule.js';

const mk = (o) => createCourse(o);
const all = [
  mk({ name: '单周课', dayOfWeek: 1, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'single' }),
  mk({ name: '双周课', dayOfWeek: 1, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'double' }),
  mk({ name: '每周课', dayOfWeek: 2, startTime: '14:00', endTime: '15:40', startWeek: 3, endWeek: 8, weekParity: 'both' }),
  mk({ name: '跨午夜', dayOfWeek: 3, startTime: '22:00', endTime: '00:30', startWeek: 1, endWeek: 16, weekParity: 'both' }),
];

assert.equal(timeToMinutes('08:00'), 480);
assert.equal(timeToMinutes('9:05'), 545);
assert.equal(timeToMinutes('25:00'), null, '非法小时');
assert.equal(timeToMinutes('abc'), null);
assert.equal(isValidTime('23:59'), true);

assert.equal(coursesForWeek(all, 1).map((c) => c.name).join(','), '单周课,跨午夜', '第1周(单)：单周课；每周课起始周3未开始');
assert.equal(coursesForWeek(all, 2).map((c) => c.name).join(','), '双周课,跨午夜', '第2周(双)：双周课；每周课起始周3未开始');
assert.equal(coursesForWeek(all, 3).map((c) => c.name).join(','), '单周课,每周课,跨午夜', '第3周(单)：每周课开始出现');
assert.equal(coursesForWeek(all, 9).map((c) => c.name).join(','), '单周课,跨午夜', '第9周(单)：每周课已结束');

assert.equal(coursesForDay(all, 1).length, 2);

// 当前/下一节：周一 09:00 正在上单周课，下一节双周课
let r = currentAndNext(all, new Date(2026, 8, 7, 9, 0));
assert.equal(r.current.name, '单周课');
assert.equal(r.next.name, '双周课');
assert.equal(r.next.startDate.getHours(), 10);

// 周一 12:30：上午课都结束，无下一节
r = currentAndNext(all, new Date(2026, 8, 7, 12, 30));
assert.equal(r.current, null);
assert.equal(r.next, null);

// 跨午夜：周三 23:00 是当前课（结束时间 00:30 在次日）
r = currentAndNext(all, new Date(2026, 8, 9, 23, 0)); // 2026-09-09 周三
assert.equal(r.current.name, '跨午夜');

// 周四 00:15：跨午夜课已结束（属于周三），无当前课
r = currentAndNext(all, new Date(2026, 8, 10, 0, 15)); // 周四
assert.equal(r.current, null);

// 周日 dayOfWeek=7 映射
const sunCourse = mk({ name: '周日课', dayOfWeek: 7, startTime: '09:00', endTime: '10:00', startWeek: 1, endWeek: 16 });
r = currentAndNext([sunCourse], new Date(2026, 8, 13, 9, 30)); // 2026-09-13 周日
assert.equal(r.current.name, '周日课');

// 倒计时文本
const target = new Date(2026, 8, 7, 10, 0, 0);
assert.equal(countdownText(target, new Date(2026, 8, 7, 9, 59, 30)), '00:00:30');
assert.equal(countdownText(target, new Date(2026, 8, 7, 11, 0, 0)), '00:00:00', '已过时间不出现负数');
console.log('✔ schedule.test');
