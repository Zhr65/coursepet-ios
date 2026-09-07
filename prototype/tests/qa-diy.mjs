// 验证：背景 DIY（渐变生效）/ 动画速度（fast 帧切换频率）/ 课程颜色文案
export default async function run(page, ui) {
  const out = {};
  const openSettings = async () => {
    const snap = await ui.snapshot();
    const btn = snap.match(/@(e\d+) button "设置"/)?.[1];
    if (!btn) return false;
    await ui.click(btn);
    await page.waitForTimeout(300);
    return true;
  };

  // 1) 渐变背景保存后生效
  if (!(await openSettings())) return { error: 'no settings' };
  await page.selectOption('#set-bg-mode', 'gradient');
  await page.selectOption('#set-bg-gradient', 'ocean');
  await page.click('#set-save');
  await page.waitForTimeout(400);
  out.gradientLayer = await page.evaluate(() => {
    const l = document.getElementById('bg-layer');
    return { display: l.style.display, bg: l.style.background, opacity: l.style.opacity };
  });

  // 2) 动画速度切 fast，采样 1.5 秒内的帧变化次数
  if (!(await openSettings())) return { error: 'no settings 2' };
  await page.selectOption('#set-speed', 'fast');
  await page.click('#set-save');
  await page.waitForTimeout(300);
  out.frameChanges = await page.evaluate(async () => {
    const img = document.getElementById('pet-img');
    let last = img.src, changes = 0;
    for (let i = 0; i < 10; i++) {
      await new Promise((r) => setTimeout(r, 150));
      if (img.src !== last) { changes++; last = img.src; }
    }
    return changes;
  });

  // 3) 课程表单颜色下拉的文案
  const snap = await ui.snapshot();
  const addBtn = snap.match(/@(e\d+) button "＋ 课程"/)?.[1];
  if (addBtn) {
    await ui.click(addBtn);
    await page.waitForTimeout(300);
    out.colorOptions = await page.evaluate(() =>
      [...document.querySelectorAll('#cf-color option')].map((o) => o.textContent).join(','));
  }
  return out;
}
