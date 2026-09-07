// 最终验证：手机宽度单列布局 / 清空数据空状态 / 刷新持久化
export default async function run(page, ui) {
  // 手机宽度（iPhone 尺寸）→ 周视图应为单列
  await page.setViewportSize({ width: 390, height: 844 });
  await page.waitForTimeout(400);
  const mobileGrid = await page.evaluate(() =>
    getComputedStyle(document.getElementById('week-grid')).gridTemplateColumns.split(' ').length);

  // 回桌面宽度，清空数据 → 空状态引导
  await page.setViewportSize({ width: 1200, height: 800 });
  const snap = await ui.snapshot();
  const btn = snap.match(/@(e\d+) button "设置"/)?.[1];
  if (!btn) return { error: 'no settings button' };
  await ui.click(btn);
  await page.waitForTimeout(300);
  page.on('dialog', (d) => d.accept());   // 自动点掉 confirm
  await page.click('#set-reset');
  await page.waitForTimeout(400);
  const emptyText = await page.evaluate(() => document.querySelector('.week-empty')?.innerText ?? null);

  // 刷新后空状态保持（localStorage 持久化）
  await page.reload();
  await page.waitForSelector('.week-empty', { timeout: 8000 });
  const emptyAfterReload = await page.evaluate(() => !!document.querySelector('.week-empty'));

  return { mobileGridCols: mobileGrid, emptyText, emptyAfterReload };
}
