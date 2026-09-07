// 验证设置：深色即时预览 / 切换角色 / 模拟电量低 → 宠物切 weak
export default async function run(page, ui) {
  const openSettings = async () => {
    const snap = await ui.snapshot();
    const btn = snap.match(/@(e\d+) button "设置"/)?.[1];
    if (!btn) return false;
    await ui.click(btn);
    await page.waitForTimeout(300);
    return true;
  };

  if (!(await openSettings())) return { error: 'no settings button' };

  // 深色模式即时预览（勾上再取消，验证双向生效）
  await page.click('#set-dark');
  await page.waitForTimeout(100);
  const themeOn = await page.evaluate(() => document.documentElement.dataset.theme);
  await page.click('#set-dark');
  const themeOff = await page.evaluate(() => document.documentElement.dataset.theme);

  // 切换角色 2 并保存
  await page.selectOption('#set-char', 'char2');
  await page.click('#set-save');
  await page.waitForTimeout(400);
  const petSrcChar2 = await page.evaluate(() =>
    document.getElementById('pet-img').src.split('/').slice(-3).join('/'));

  // 再开设置：勾模拟电量低并保存 → 宠物应立即切到 weak
  if (!(await openSettings())) return { error: 'settings did not reopen' };
  await page.click('#set-sim-low');
  await page.click('#set-save');
  await page.waitForTimeout(400);
  const petSrcWeak = await page.evaluate(() =>
    document.getElementById('pet-img').src.split('/').slice(-3).join('/'));
  const bubble = await page.evaluate(() => document.getElementById('pet-bubble').textContent);

  return { themeOn, themeOff, petSrcChar2, petSrcWeak, bubble };
}
