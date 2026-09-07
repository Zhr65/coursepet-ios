// 装配入口：store + 状态机 + 周视图 + 宠物 + 倒计时定时器
import { createStore } from './store.js';
import { currentWeekNumber, weekParityOf, formatDate } from './week.js';
import { coursesForWeek } from './schedule.js';
import { decideAction, bubbleFor } from './pet-state.js';
import { demoCourses } from './demo-data.js';
import { renderWeek, updateCountdown } from './ui/week-view.js';
import { initPet } from './ui/pet.js';
import { initImport } from './ui/import.js';

const store = createStore(localStorage);
let state = store.load();

// 首次使用：学期开始日设为今天 + 演示课表
if (!state.semester.startDate) {
  state.semester.startDate = formatDate(new Date());
  state.courses = demoCourses();
  store.save(state);
}

const weekTitle = document.getElementById('week-title');
const weekGrid = document.getElementById('week-grid');
const countdownBar = document.getElementById('countdown-bar');
const btnPrev = document.getElementById('btn-prev-week');
const btnNext = document.getElementById('btn-next-week');
const btnThis = document.getElementById('btn-this-week');

let viewingWeek = currentWeekNumber(state.semester.startDate) || 1;

function render() {
  const weekNumber = currentWeekNumber(state.semester.startDate);
  const parity = weekParityOf(viewingWeek);
  const prefix = viewingWeek === weekNumber ? '' : '（查看中）';
  weekTitle.textContent = `第 ${viewingWeek} 周 · ${parity === 'single' ? '单周' : '双周'}${prefix}`;
  const now = new Date();
  renderWeek(weekGrid, coursesForWeek(state.courses, viewingWeek), viewingWeek === weekNumber ? now : new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59));
  updateCountdown(countdownBar, coursesForWeek(state.courses, weekNumber), now);
}

btnPrev.addEventListener('click', () => { viewingWeek = Math.max(1, viewingWeek - 1); render(); });
btnNext.addEventListener('click', () => { viewingWeek += 1; render(); });
btnThis.addEventListener('click', () => { viewingWeek = currentWeekNumber(state.semester.startDate) || 1; render(); });

setInterval(() => updateCountdown(countdownBar, coursesForWeek(state.courses, currentWeekNumber(state.semester.startDate) || 1), new Date()), 1000);

// 宠物
const petImg = document.getElementById('pet-img');
const petBubble = document.getElementById('pet-bubble');
let lastClickAt = null;
const pet = initPet(petImg, petBubble, {
  getCharId: () => state.settings.charId,
  getSpeed: () => state.settings.animSpeed,
  onClick: () => { lastClickAt = new Date(); refreshPet(); },
});

function refreshPet() {
  const ctx = {
    now: new Date(),
    courses: coursesForWeek(state.courses, currentWeekNumber(state.semester.startDate) || 1),
    charging: state.settings.simCharging,
    lowBattery: state.settings.simLowBattery,
    music: state.settings.simMusic,
    lastClickAt,
  };
  const r = decideAction(ctx);
  if (r.action !== pet.getAction()) pet.play(r.action);
  if (r.bubble) pet.showBubble(r.bubble);
  else if (Math.random() < 0.3) pet.showBubble(bubbleFor(state.pet.mood));
}
setInterval(refreshPet, 30000);

// 导入
initImport({
  onImport: (courses) => {
    state.courses = state.courses.concat(courses); // 追加；清空走设置里的「清空全部数据」
    store.save(state);
    render();
    refreshPet();
  },
});

render();
refreshPet();
