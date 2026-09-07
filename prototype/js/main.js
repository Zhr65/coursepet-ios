// 装配入口：store + 状态机 + 周视图 + 倒计时定时器
import { createStore } from './store.js';
import { currentWeekNumber, weekParityOf, formatDate } from './week.js';
import { coursesForWeek } from './schedule.js';
import { demoCourses } from './demo-data.js';
import { renderWeek, updateCountdown } from './ui/week-view.js';

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
render();
