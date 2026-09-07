// 验证养成面板：初始值 → 喂食增减 → 非上课时段打卡被拒
export default async function run(page, ui) {
  const snap = await ui.snapshot();
  const btn = snap.match(/@(e\d+) button "🍙 养成"/)?.[1];
  if (!btn) return { error: 'no feed button', snapshot: snap };

  await ui.click(btn);
  await page.waitForTimeout(300);

  const before = await page.evaluate(() => ({
    mood: document.getElementById('feed-mood').textContent,
    aff: document.getElementById('feed-aff').textContent,
    food: document.getElementById('feed-food').textContent,
  }));

  await page.click('#feed-give');
  await page.waitForTimeout(200);
  const afterFeed = await page.evaluate(() => ({
    mood: document.getElementById('feed-mood').textContent,
    aff: document.getElementById('feed-aff').textContent,
    food: document.getElementById('feed-food').textContent,
  }));

  await page.click('#feed-checkin');
  await page.waitForTimeout(200);
  const toastText = await page.evaluate(() => document.getElementById('toast').textContent);

  return { before, afterFeed, checkinToast: toastText };
}
