// 养成面板：心情/好感度/食物 + 喂食 + 上课打卡
import { openDialog, toast } from './dialogs.js';
import { coursesForWeek, currentAndNext } from '../schedule.js';
import { currentWeekNumber } from '../week.js';

export function initFeed({ getState, save }) {
  document.getElementById('btn-feed').addEventListener('click', () => {
    const st = getState();
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <div style="display:flex;gap:20px;justify-content:center;margin:8px 0 16px">
        <div style="text-align:center"><div id="feed-mood" style="font-size:30px">–</div><div style="font-size:12px;color:var(--fg-dim)">心情</div></div>
        <div style="text-align:center"><div id="feed-aff" style="font-size:30px">–</div><div style="font-size:12px;color:var(--fg-dim)">好感度</div></div>
        <div style="text-align:center"><div id="feed-food" style="font-size:30px">–</div><div style="font-size:12px;color:var(--fg-dim)">食物</div></div>
      </div>
      <p style="font-size:13px;color:var(--fg-dim);text-align:center">上课时来打卡获得食物；食物可喂给宠物提升心情和好感度</p>
      <div class="btn-row" style="justify-content:center">
        <button id="feed-give" class="btn primary">🍙 喂食（-1 食物 +10 心情）</button>
        <button id="feed-checkin" class="btn">📚 上课打卡</button>
      </div>`;
    const dlg = openDialog(`${st.pet.name} 的养成面板`, body);
    const moodEl = body.querySelector('#feed-mood');
    const affEl = body.querySelector('#feed-aff');
    const foodEl = body.querySelector('#feed-food');

    function renderStats() {
      const s = getState();
      moodEl.textContent = s.pet.mood;
      affEl.textContent = s.pet.affection;
      foodEl.textContent = s.pet.food;
    }
    renderStats();

    body.querySelector('#feed-give').addEventListener('click', () => {
      const s = getState();
      if (s.pet.food <= 0) { toast('没有食物啦，快去上课打卡！'); return; }
      s.pet.food -= 1;
      s.pet.mood = Math.min(100, s.pet.mood + 10);
      s.pet.affection = Math.min(100, s.pet.affection + 2);
      save();
      renderStats();
      toast(`${s.pet.name} 开心地吃掉了食物！`);
    });

    body.querySelector('#feed-checkin').addEventListener('click', () => {
      const s = getState();
      const week = currentWeekNumber(s.semester.startDate) || 1;
      const { current } = currentAndNext(coursesForWeek(s.courses, week), new Date());
      if (!current) { toast('现在没有在上课哦，打卡失败'); return; }
      s.pet.food += 1;
      s.pet.mood = Math.min(100, s.pet.mood + 10);
      s.pet.affection = Math.min(100, s.pet.affection + 5);
      save();
      renderStats();
      toast('打卡成功！获得 1 个食物 🍙');
    });
  });
}
