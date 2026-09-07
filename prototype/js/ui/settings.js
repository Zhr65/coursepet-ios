// 设置面板：学期开始日/动画速度/角色/模拟开关/深色模式/背景DIY/宠物名/清空数据
import { openDialog, toast } from './dialogs.js';

// 渐变预设（背景 DIY 用，main.js 也引用）
export const GRADIENTS = {
  sunset: ['#FF9A76', '#FFD3A5'],   // 日落
  ocean: ['#7FB5FF', '#BDEBFF'],    // 海洋
  forest: ['#8FD3A8', '#DFF3E3'],   // 森林
  starry: ['#2B3A67', '#7A6FBE'],   // 星空
  sakura: ['#FFB7C5', '#FFF0F0'],   // 樱花
  mint: ['#7FD8C9', '#DFF7F2'],     // 薄荷
};

/** 图片压缩为 dataURL（最长边 1920，JPEG 0.8，避免撑爆 localStorage） */
function compressImage(file) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 1920 / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      resolve(canvas.toDataURL('image/jpeg', 0.8));
    };
    img.onerror = () => reject(new Error('图片读取失败'));
    img.src = URL.createObjectURL(file);
  });
}

export function initSettings({ getState, save, onChanged }) {
  document.getElementById('btn-settings').addEventListener('click', () => {
    const s = getState();
    const bg = s.settings.bg || {};
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
      <h4 style="margin:16px 0 8px">背景 DIY（参考 Mineradio）</h4>
      <div class="form-row"><label for="set-bg-mode">背景模式</label>
        <select id="set-bg-mode">
          <option value="default" ${bg.mode === 'default' ? 'selected' : ''}>默认（跟随主题）</option>
          <option value="color" ${bg.mode === 'color' ? 'selected' : ''}>纯色</option>
          <option value="gradient" ${bg.mode === 'gradient' ? 'selected' : ''}>渐变</option>
          <option value="image" ${bg.mode === 'image' ? 'selected' : ''}>自定义图片</option>
        </select></div>
      <div class="form-row" id="row-bg-color"><label for="set-bg-color">背景颜色</label>
        <input id="set-bg-color" type="color" value="${bg.color || '#FFD9C9'}"></div>
      <div class="form-row" id="row-bg-gradient"><label for="set-bg-gradient">渐变方案</label>
        <select id="set-bg-gradient">${Object.entries(GRADIENTS).map(([k, v]) => `<option value="${k}" ${(bg.gradient || 'sunset') === k ? 'selected' : ''}>${k}</option>`).join('')}</select></div>
      <div class="form-row" id="row-bg-image"><label>背景图片（上传后自动压缩）</label>
        <input id="set-bg-image" type="file" accept="image/*">
        <div id="set-bg-image-state" style="font-size:12px;color:var(--fg-dim);margin-top:4px">${bg.image ? '✅ 已设置图片' : '未设置'}</div></div>
      <div class="form-row"><label for="set-bg-opacity">背景透明度 <span id="set-bg-opacity-val"></span></label>
        <input id="set-bg-opacity" type="range" min="0.05" max="1" step="0.05" value="${bg.opacity ?? 0.6}"></div>
      <div class="btn-row">
        <button id="set-reset" class="btn" style="color:var(--danger)">清空全部数据</button>
        <button id="set-save" class="btn primary">保存</button>
      </div>`;
    const dlg = openDialog('设置', body);

    // 背景 DIY：按模式显隐对应控件 + 透明度数值显示
    const modeSel = body.querySelector('#set-bg-mode');
    const opSlider = body.querySelector('#set-bg-opacity');
    const opVal = body.querySelector('#set-bg-opacity-val');
    function syncBgRows() {
      const m = modeSel.value;
      body.querySelector('#row-bg-color').style.display = m === 'color' ? '' : 'none';
      body.querySelector('#row-bg-gradient').style.display = m === 'gradient' ? '' : 'none';
      body.querySelector('#row-bg-image').style.display = m === 'image' ? '' : 'none';
      opVal.textContent = opSlider.value;
    }
    modeSel.addEventListener('change', syncBgRows);
    opSlider.addEventListener('input', () => { opVal.textContent = opSlider.value; });
    syncBgRows();

    // 图片上传即时压缩为 dataURL（保存时才写入设置）
    let pendingImage = bg.image || '';
    body.querySelector('#set-bg-image').addEventListener('change', async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      try {
        pendingImage = await compressImage(file);
        body.querySelector('#set-bg-image-state').textContent = '✅ 已选择图片（保存后生效）';
      } catch (err) {
        toast('图片读取失败，换个文件试试');
      }
    });

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
      st.settings.bg = {
        mode: modeSel.value,
        color: body.querySelector('#set-bg-color').value,
        gradient: body.querySelector('#set-bg-gradient').value,
        image: pendingImage,
        opacity: Number(opSlider.value),
      };
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
