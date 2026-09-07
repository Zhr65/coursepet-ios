// 宠物帧动画播放器：循环动作 vs 单次触发动作；点击互动 + 气泡
const FRAME_COUNT = 8;
const LOOP_ACTIONS = new Set(['idle', 'walk', 'listen', 'sleep', 'weak', 'rain', 'charge']);
const SPEED_MS = { slow: 700, mid: 500, fast: 300 };   // 循环动作每帧时长
const ONCE_MS = { slow: 320, mid: 220, fast: 140 };    // 触发动作每帧时长

export function initPet(imgEl, bubbleEl, { getCharId, getSpeed, onClick }) {
  let action = 'idle';
  let loopTimer = null, onceTimer = null, bubbleTimer = null;

  function frameUrl(a, i) { return `../pet_assets/${getCharId()}/pet_${a}_${i}.png`; }

  function play(a) {
    action = a;
    clearInterval(loopTimer);
    clearInterval(onceTimer);
    imgEl.src = frameUrl(a, 0);
    let frame = 0;
    if (LOOP_ACTIONS.has(a)) {
      loopTimer = setInterval(() => {
        frame = (frame + 1) % FRAME_COUNT;
        imgEl.src = frameUrl(a, frame);
      }, SPEED_MS[getSpeed()]);
    } else {
      // 触发动作播一遍后回待机
      onceTimer = setInterval(() => {
        frame += 1;
        if (frame >= FRAME_COUNT) { clearInterval(onceTimer); play('idle'); return; }
        imgEl.src = frameUrl(a, frame);
      }, ONCE_MS[getSpeed()]);
    }
  }

  function showBubble(text) {
    if (!text) { bubbleEl.classList.add('hidden'); bubbleEl.textContent = ''; return; }
    bubbleEl.textContent = text;
    bubbleEl.classList.remove('hidden');
    clearTimeout(bubbleTimer);
    bubbleTimer = setTimeout(() => bubbleEl.classList.add('hidden'), 4000);
  }

  imgEl.addEventListener('click', () => {
    if (navigator.vibrate) navigator.vibrate(20);
    onClick();
  });

  // 初始就播放待机动画（否则 action 恒为 idle，外部判断不触发 play，图片永远是空的）
  play('idle');

  return { play, showBubble, getAction: () => action };
}
