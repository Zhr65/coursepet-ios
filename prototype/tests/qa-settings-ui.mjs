// 验证：今天列粉色描边 / 玻璃态弹层 / 渐变中文 / 设置分区标题
export default async function run(page, ui) {
  const out = {};
  // 今天列描边颜色
  out.todayOutline = await page.evaluate(() =>
    getComputedStyle(document.querySelector('.day-col.today')).outlineColor);
  // 打开设置
  const snap = await ui.snapshot();
  const btn = snap.match(/@(e\d+) button "设置"/)?.[1];
  await ui.click(btn);
  await page.waitForTimeout(400);
  out.dialog = await page.evaluate(() => {
    const d = document.querySelector('.dialog');
    const s = getComputedStyle(d);
    return {
      title: d.querySelector('h3').textContent,
      bg: s.backgroundColor,
      blur: s.backdropFilter,
      sections: [...d.querySelectorAll('.set-section')].map((h) => h.textContent.trim()).join('/'),
      gradientOptions: [...document.querySelectorAll('#set-bg-gradient option')].map((o) => o.textContent).join(','),
    };
  });
  return out;
}
