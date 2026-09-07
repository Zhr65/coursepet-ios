// 设置面板：学期开始日/动画速度/角色/模拟开关/深色模式/宠物名/清空数据
import { openDialog, toast } from './dialogs.js';

export function initSettings({ getState, save, onChanged }) {
  document.getElementById('btn-settings').addEventListener('click', () => {
    const s = getState();
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <div class="form-row"><label for="set-name">宠物名字</label><input id="set-name" value="${s.pet.name}"></div>
      <div class="form-row"><label for="set-start">学期开始日期（当天=第1周·单周）</label>
        <input id="set-start" type="date" value="${s.semester.startDate}"></div>
      <div class="form-row"><label for="set-speed">动画速度</label>
        <select id="set-speed">
          <option value="slow" ${s.settings.animSpeed === 'slow' ? 'selected' : ''}>慢</option>
          <option value="mid" ${s.settings.animSpeed === 'mid' ? 'selected' : ''}>中</option>
          <option value="fast" ${s.settings.animSpeed === 'fast' ? 'selected' : ''}>快</option>
        </select></div>
      <div class="form-row"><label for="set-char">宠物形象</label>
        <select id="set-char">
          ${[1, 2, 3].map((n) => `<option value="char${n}" ${s.settings.charId === `char${n}` ? 'selected' : ''}>角色 ${n}</option>`).join('')}
        </select></div>
      <div class="form-row"><label>系统状态模拟（原型期替代真实电量/音乐）</label>
        <label style="display:flex;align-items:center;gap:8px;font-size:14px;margin:6px 0"><input type="checkbox" id="set-sim-low" ${s.settings.simLowBattery ? 'checked' : ''}> 模拟电量低</label>
        <label style="display:flex;align-items:center;gap:8px;font-size:14px;margin:6px 0"><input type="checkbox" id="set-sim-charge" ${s.settings.simCharging ? 'checked' : ''}> 模拟充电中</label>
        <label style="display:flex;align-items:center;gap:8px;font-size:14px;margin:6px 0"><input type="checkbox" id="set-sim-music" ${s.settings.simMusic ? 'checked' : ''}> 模拟播放音乐</label>
      </div>
      <div class="form-row">
        <label style="display:flex;align-items:center;gap:8px;font-size:14px"><input type="checkbox" id="set-dark" ${s.settings.darkMode ? 'checked' : ''}> 深色模式</label>
      </div>
      <div class="btn-row">
        <button id="set-reset" class="btn" style="color:var(--danger)">清空全部数据</button>
        <button id="set-save" class="btn primary">保存</button>
      </div>`;
    const dlg = openDialog('设置', body);

    // 深色模式即时预览（保存前就能看效果）
    body.querySelector('#set-dark').addEventListener('change', (e) => {
      document.documentElement.dataset.theme = e.target.checked ? 'dark' : 'light';
    });

    body.querySelector('#set-save').addEventListener('click', () => {
      const st = getState();
      st.pet.name = body.querySelector('#set-name').value.trim() || '小火人';
      st.semester.startDate = body.querySelector('#set-start').value;
      st.settings.animSpeed = body.querySelector('#set-speed').value;
      st.settings.charId = body.querySelector('#set-char').value;
      st.settings.simLowBattery = body.querySelector('#set-sim-low').checked;
      st.settings.simCharging = body.querySelector('#set-sim-charge').checked;
      st.settings.simMusic = body.querySelector('#set-sim-music').checked;
      st.settings.darkMode = body.querySelector('#set-dark').checked;
      document.documentElement.dataset.theme = st.settings.darkMode ? 'dark' : 'light';
      save();
      dlg.close();
      toast('设置已保存');
      onChanged();
    });

    body.querySelector('#set-reset').addEventListener('click', () => {
      if (!confirm('确定清空全部数据（课表/养成进度/设置）？')) return;
      const st = getState();
      st.courses = [];
      st.pet.mood = 70; st.pet.affection = 0; st.pet.food = 5;
      save();
      dlg.close();
      toast('已清空');
      onChanged();
    });
  });
}
