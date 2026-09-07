// 端到端验证：打开导入弹层 → 上传示例 xlsx → 检查映射/预览 → 确认导入 → 检查网格
export default async function run(page, ui) {
  const snap = await ui.snapshot();
  const btn = snap.match(/@(e\d+) button "＋ 导入课表"/)?.[1];
  if (!btn) return { error: 'no import button', snapshot: snap };

  await ui.click(btn);
  await page.waitForTimeout(400);

  await page.setInputFiles('#import-file', 'D:/AI/CoursePet/prototype/sample_files/课表示例.xlsx');
  await page.waitForSelector('#import-preview:not(.hidden)', { timeout: 20000 });

  const preview = await page.evaluate(() => document.getElementById('import-preview').innerText.slice(0, 400));
  const confirmDisabled = await page.evaluate(() => document.getElementById('import-confirm').disabled);
  const mappingCount = await page.evaluate(() => document.querySelectorAll('#import-mapping select').length);

  await page.click('#import-confirm');
  await page.waitForTimeout(400);

  const blocks = await page.evaluate(() => document.querySelectorAll('.course-block').length);
  const toastText = await page.evaluate(() => document.getElementById('toast').textContent);
  return { preview, confirmDisabled, mappingCount, blocksAfterImport: blocks, toastText };
}
