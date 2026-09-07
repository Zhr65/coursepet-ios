// localStorage 持久化（storage 可注入，便于测试）
export const DEFAULT_STATE = {
  version: 1,
  semester: { startDate: '' },   // 'YYYY-MM-DD'
  courses: [],
  pet: { name: '小火人', mood: 70, affection: 0, food: 5 },
  settings: {
    animSpeed: 'mid',            // slow|mid|fast
    simLowBattery: false, simCharging: false, simMusic: false, // 原型期模拟开关
    darkMode: false,
    charId: 'char1',             // pet_assets 下的角色目录
    bg: { mode: 'default', color: '#FFD9C9', gradient: 'sunset', image: '', opacity: 0.6 },
  },
};

export function mergeDefaults(s) {
  return {
    ...DEFAULT_STATE, ...s,
    semester: { ...DEFAULT_STATE.semester, ...(s.semester || {}) },
    pet: { ...DEFAULT_STATE.pet, ...(s.pet || {}) },
    settings: { ...DEFAULT_STATE.settings, ...(s.settings || {}) },
  };
}

export function createStore(storage) {
  return {
    load() {
      try {
        const raw = storage.getItem('coursepet');
        return raw ? mergeDefaults(JSON.parse(raw)) : mergeDefaults({});
      } catch (e) {
        return mergeDefaults({});
      }
    },
    save(state) { storage.setItem('coursepet', JSON.stringify(state)); },
  };
}
