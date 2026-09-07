// 验证课程增删改：添加 → 编辑改名 → 删除
export default async function run(page, ui) {
  page.on('dialog', (d) => d.accept()); // 自动点掉删除确认框

  // 1) 添加课程
  const snap = await ui.snapshot();
  const addBtn = snap.match(/@(e\d+) button "＋ 课程"/)?.[1];
  if (!addBtn) return { error: 'no add button', snapshot: snap };
  await ui.click(addBtn);
  await page.waitForTimeout(300);
  await page.fill('#cf-name', '测试课');
  await page.fill('#cf-location', '测试楼101');
  await page.selectOption('#cf-day', '6');
  await page.fill('#cf-start', '15:00');
  await page.fill('#cf-end', '16:00');
  await page.click('#cf-save');
  await page.waitForTimeout(400);
  const added = await page.evaluate(() =>
    [...document.querySelectorAll('.course-block')].some((b) => b.textContent.includes('测试课')));

  // 2) 点击该课程块 → 编辑改名
  await page.locator('.course-block', { hasText: '测试课' }).click();
  await page.waitForTimeout(300);
  await page.fill('#cf-name', '测试课改');
  await page.click('#cf-save');
  await page.waitForTimeout(400);
  const renamed = await page.evaluate(() =>
    [...document.querySelectorAll('.course-block')].some((b) => b.textContent.includes('测试课改')));

  // 3) 再点击 → 删除
  await page.locator('.course-block', { hasText: '测试课改' }).click();
  await page.waitForTimeout(300);
  await page.click('#cf-delete');
  await page.waitForTimeout(400);
  const deleted = await page.evaluate(() =>
    ![...document.querySelectorAll('.course-block')].some((b) => b.textContent.includes('测试课改')));

  return { added, renamed, deleted };
}
