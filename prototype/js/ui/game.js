// 课间小游戏：接零食（canvas，60 秒，得分换食物）
import { openDialog, toast } from './dialogs.js';

export function initGame({ getState, save }) {
  document.getElementById('btn-game').addEventListener('click', () => {
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <canvas id="game-canvas" width="360" height="400"
        style="width:100%;max-width:360px;display:block;margin:0 auto;background:var(--bg);border-radius:12px;touch-action:none;"></canvas>
      <p id="game-info" style="text-align:center;font-size:14px">得分 0 · 剩余 60 秒 · ←→ 键或拖动篮子</p>`;
    const dlg = openDialog('接零食小游戏', body);
    const canvas = body.querySelector('#game-canvas');
    const ctx = canvas.getContext('2d');
    const info = body.querySelector('#game-info');
    const SNACKS = ['🍪', '🍬', '🍎', '🍙', '🍰'];
    const B_W = 90;                        // 篮子宽度
    let basketX = 180, score = 0, timeLeft = 60, last = 0, raf = null;
    let items = [];

    function move(x) { basketX = Math.max(B_W / 2, Math.min(360 - B_W / 2, x)); }

    function step(now) {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      timeLeft -= dt;
      for (const it of items) {
        it.y += it.v * dt;
        if (it.y > 380 && Math.abs(it.x - basketX) < B_W / 2 + 12) { score += 10; it.y = -999; }
      }
      items = items.filter((it) => it.y < 420 && it.y > -999);
      if (items.length < 6 && Math.random() < 0.5) {
        items.push({ x: 20 + Math.random() * 320, y: -20, v: 60 + Math.random() * 50, e: SNACKS[Math.floor(Math.random() * SNACKS.length)] });
      }
      if (timeLeft <= 0) {
        cancelAnimationFrame(raf);
        const st = getState();
        const gained = Math.floor(score / 10);
        st.pet.food += gained;
        st.pet.mood = Math.min(100, st.pet.mood + 5);
        save();
        info.innerHTML = `结束！得分 ${score}，兑换 ${gained} 个食物 🍙（已加入养成面板）`;
        toast(`获得 ${gained} 个食物！`);
        return;
      }
      draw();
      raf = requestAnimationFrame(step);
    }

    function draw() {
      ctx.clearRect(0, 0, 360, 400);
      ctx.font = '28px serif';
      for (const it of items) ctx.fillText(it.e, it.x - 14, it.y);
      ctx.fillStyle = '#FF9E7D';
      ctx.beginPath();
      ctx.ellipse(basketX, 382, B_W / 2, 14, 0, Math.PI, 0);
      ctx.fill();
      info.textContent = `得分 ${score} · 剩余 ${Math.max(0, Math.ceil(timeLeft))} 秒 · ←→ 键或拖动篮子`;
    }

    function onKey(e) {
      if (e.key === 'ArrowLeft') move(basketX - 24);
      if (e.key === 'ArrowRight') move(basketX + 24);
    }
    window.addEventListener('keydown', onKey);
    canvas.addEventListener('pointerdown', (e) => canvas.setPointerCapture(e.pointerId));
    canvas.addEventListener('pointermove', (e) => {
      const r = canvas.getBoundingClientRect();
      move((e.clientX - r.left) * 360 / r.width);
    });
    dlg.setOnClose(() => {
      cancelAnimationFrame(raf);
      window.removeEventListener('keydown', onKey);
    });

    raf = requestAnimationFrame((t) => { last = t; raf = requestAnimationFrame(step); });
    draw();
  });
}
