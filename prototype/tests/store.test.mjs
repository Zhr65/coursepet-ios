import assert from 'node:assert';
import { createStore, mergeDefaults, DEFAULT_STATE } from '../js/store.js';
import { demoCourses } from '../js/demo-data.js';

// 内存假 storage，模拟 localStorage
function memStorage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v), _m: m };
}

const s1 = memStorage();
const store = createStore(s1);
const state = store.load();
assert.equal(state.pet.name, '小火人', '默认宠物名');
assert.equal(state.settings.animSpeed, 'mid');
assert.deepEqual(state.courses, []);
store.save({ ...state, pet: { ...state.pet, food: 3 } });
const state2 = createStore(memStorage()).load();
assert.equal(state2.pet.food, 5, '新 storage 读不到旧数据');

const loaded = createStore(s1).load();
assert.equal(loaded.pet.food, 3, '保存后能读回');
assert.equal(loaded.settings.charId, 'char1', '未保存的字段用默认值补全');

// 损坏 JSON 不崩
const bad = memStorage();
bad.setItem('coursepet', '{oops');
assert.equal(createStore(bad).load().pet.name, '小火人');

// 演示数据：7 条课程、字段完整
const demo = demoCourses();
assert.equal(demo.length, 7);
assert.ok(demo.every((c) => c.name && c.dayOfWeek >= 1 && c.dayOfWeek <= 7 && c.startTime < c.endTime));
assert.ok(demo.some((c) => c.weekParity === 'single') && demo.some((c) => c.weekParity === 'double'));
console.log('✔ store.test');
