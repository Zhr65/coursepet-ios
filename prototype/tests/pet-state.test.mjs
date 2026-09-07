import assert from 'node:assert';
import { decideAction, bubbleFor } from '../js/pet-state.js';
import { createCourse } from '../js/schedule.js';

const mk = (o) => createCourse(o);
const courses = [
  mk({ name: '数学', dayOfWeek: 1, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
  mk({ name: '英语', dayOfWeek: 1, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
];
const base = (o) => ({ now: new Date(2026, 8, 7, 12, 0), courses, lowBattery: false, charging: false, music: false, lastClickAt: null, ...o });
const rand = () => 0.5; // 固定随机源，保证可复现

assert.equal(decideAction(base({ charging: true }), rand).action, 'charge', '充电优先');
assert.equal(decideAction(base({ lowBattery: true }), rand).action, 'weak', '低电量次之');
assert.equal(decideAction(base({ music: true }), rand).action, 'listen', '音乐再次之');

// 点击 5 秒内 → 开心/兴奋（rand=0.9 → <0.5 为 false → excite）
const click = decideAction(base({ lastClickAt: new Date(2026, 8, 7, 12, 0, 1) }), () => 0.9);
assert.ok(['happy', 'excite'].includes(click.action), '点击触发挥发性动作');

// 课前 15 分钟内 → nervous（10:00 的课，当前 09:50）
const pre = decideAction(base({ now: new Date(2026, 8, 7, 9, 50) }), rand);
assert.equal(pre.action, 'nervous');

// 上课中 rand=0.9 → idle；rand=0.1 → sleep
assert.equal(decideAction(base({ now: new Date(2026, 8, 7, 8, 30) }), () => 0.9).action, 'idle');
assert.equal(decideAction(base({ now: new Date(2026, 8, 7, 8, 30) }), () => 0.1).action, 'sleep');

// 课后 10 分钟内 → walk/excite（英语 11:40 下课，11:45 无下一节，不再触发课前紧张）
const after = decideAction(base({ now: new Date(2026, 8, 7, 11, 45) }), () => 0.9);
assert.ok(['walk', 'excite'].includes(after.action), '课后10分钟内为活跃动作');

// 09:45 同时满足「课后5分钟」与「课前15分钟」：按设计优先级，课前紧张应胜出
const overlap = decideAction(base({ now: new Date(2026, 8, 7, 9, 45) }), rand);
assert.equal(overlap.action, 'nervous', '课前15分钟优先级高于课间活跃');

// 课间平静期 → idle
assert.equal(decideAction(base({ now: new Date(2026, 8, 7, 12, 0) }), rand).action, 'idle');

// 气泡按心情分段
assert.ok(bubbleFor(90, () => 0).length > 0);
assert.ok(bubbleFor(20, () => 0).length > 0);
assert.ok(bubbleFor(50, () => 0).length > 0);
console.log('✔ pet-state.test');
