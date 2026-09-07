// 验证小游戏：打开 → 计时走秒 → 键盘移动无报错 → 关闭后 canvas 移除
export default async function run(page, ui) {
  const snap = await ui.snapshot();
  const btn = snap.match(/@(e\d+) button "🎮 小游戏"/)?.[1];
  if (!btn) return { error: 'no game button', snapshot: snap };

  await ui.click(btn);
  await page.waitForTimeout(2600);
  const info1 = await page.evaluate(() => document.getElementById('game-info').textContent);

  await page.keyboard.press('ArrowRight');
  await page.keyboard.press('ArrowLeft');
  await page.waitForTimeout(1100);
  const info2 = await page.evaluate(() => document.getElementById('game-info').textContent);

  const snap2 = await ui.snapshot();
  const closeBtn = snap2.match(/@(e\d+) button "关闭"/)?.[1];
  if (closeBtn) await ui.click(closeBtn);
  await page.waitForTimeout(300);
  const canvasGone = await page.evaluate(() => !document.getElementById('game-canvas'));

  return { info1, info2, canvasGone };
}
