// 周视图渲染 + 倒计时条
import { coursesForDay, currentAndNext, countdownText } from '../schedule.js';

const DAY_NAMES = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (ch) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

export function renderWeek(gridEl, courses, now, onCourseClick = null) {
  const { current } = currentAndNext(courses, now);
  const dow = now.getDay() === 0 ? 7 : now.getDay();
  gridEl.innerHTML = '';
  if (!courses.length) {
    gridEl.innerHTML = `<div class="week-empty"><div class="big">📚</div>还没有课表<br>点右上角「＋ 导入课表」导入你的课表，<br>或去设置里清空数据恢复演示课表</div>`;
    return;
  }
  for (let d = 1; d <= 7; d++) {
    const col = document.createElement('section');
    col.className = 'day-col' + (d === dow ? ' today' : '');
    const head = document.createElement('h2');
    head.textContent = DAY_NAMES[d - 1];
    col.appendChild(head);
    for (const c of coursesForDay(courses, d)) {
      const block = document.createElement('div');
      block.className = 'course-block';
      block.style.background = c.color;
      if (current && current.id === c.id) block.classList.add('current');
      const name = document.createElement('div');
      name.className = 'course-name';
      name.textContent = c.name;
      const time = document.createElement('div');
      time.className = 'course-time';
      time.textContent = `${c.startTime}–${c.endTime}`;
      const loc = document.createElement('div');
      loc.className = 'course-loc';
      loc.textContent = c.location || c.teacher || '';
      block.append(name, time, loc);
      block.addEventListener('click', () => onCourseClick && onCourseClick(c));
      col.appendChild(block);
    }
    gridEl.appendChild(col);
  }
}

/** 顶部倒计时条：上课中→剩余时间；课前→距上课时间；无课→隐藏 */
export function updateCountdown(barEl, courses, now) {
  const { current, next } = currentAndNext(courses, now);
  if (current) {
    const end = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
      +current.endTime.split(':')[0], +current.endTime.split(':')[1]);
    const endMs = current.endTime <= current.startTime ? end.getTime() + 86400000 : end.getTime();
    barEl.innerHTML = `正在上「${escapeHtml(current.name)}」，剩余 <span class="time">${countdownText(endMs, now)}</span>`;
    barEl.classList.remove('hidden');
  } else if (next) {
    barEl.innerHTML = `距「${escapeHtml(next.name)}」上课 <span class="time">${countdownText(next.startDate, now)}</span>`;
    barEl.classList.remove('hidden');
  } else {
    barEl.classList.add('hidden');
  }
}
