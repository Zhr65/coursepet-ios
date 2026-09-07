# CoursePet 网页原型 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 D:\AI\CoursePet\prototype\ 构建课程表宠物的可交互网页原型（实现设计文档阶段 1 的全部范围）

**Architecture:** 纯 HTML+CSS+JS 零构建、零 npm 依赖。逻辑层（周数/课表/状态机/字段映射/存储）为无 DOM 依赖的 ES 模块，用 Node 内置 assert + 自写 runner 做 TDD；UI 层（周视图/宠物/弹层/导入/养成/设置/小游戏）为独立模块，由 main.js 装配。浏览器经本地静态服务器访问，宠物帧从 `../pet_assets/{charId}/` 加载。

**Tech Stack:** HTML5 + CSS3（自定义属性）+ ES Modules + SheetJS（CDN，仅浏览器端）+ Node（仅测试）+ Python（仅生成示例 xlsx）

**运行方式：** `cd D:\AI\CoursePet` → `python -m http.server 8017` → 浏览器打开 http://localhost:8017/prototype/ （注意：必须在项目根目录启动，pet_assets 在 prototype 上层；8000 端口被本机其他服务占用，故用 8017）

**设计文档：** `docs/superpowers/specs/2026-09-07-coursepet-design.md`

---

## 文件结构

```
prototype/
├── package.json          # {"type":"module"}（Node 下跑 ESM 测试用）
├── index.html            # 单页骨架
├── css/style.css         # 设计 token + 全部样式
├── js/
│   ├── week.js           # 周数/单双周计算（纯逻辑）
│   ├── schedule.js       # 课程模型/过滤/当前与下一节/倒计时（纯逻辑）
│   ├── pet-state.js      # 宠物状态机（纯逻辑，依赖 schedule.js）
│   ├── mapping.js        # Excel 字段映射与行解析（纯逻辑，依赖 schedule.js）
│   ├── store.js          # localStorage 存储层（可注入 storage，纯逻辑）
│   ├── demo-data.js      # 示例课表（纯逻辑）
│   ├── ui/
│   │   ├── week-view.js  # 周视图渲染 + 倒计时条
│   │   ├── pet.js        # 宠物帧动画播放器 + 点击互动 + 气泡
│   │   ├── dialogs.js    # 通用弹层 + toast
│   │   ├── import.js     # 导入流程（选文件→解析→映射→预览→入库）
│   │   ├── feed.js       # 养成面板（喂食/打卡）
│   │   ├── settings.js   # 设置面板
│   │   └── game.js       # 接零食小游戏（canvas）
│   └── main.js           # 装配：store + 状态机 + 各 UI 模块 + 1s/30s 定时器
├── tests/
│   ├── run.mjs           # 零依赖测试入口
│   ├── week.test.mjs
│   ├── schedule.test.mjs
│   ├── pet-state.test.mjs
│   ├── mapping.test.mjs
│   └── store.test.mjs
└── sample_files/         # make_sample_xlsx.py 生成的示例课表（供导入测试）
```

---

## Task 1: 项目骨架

**Files:**
- Create: `prototype/package.json`
- Create: `prototype/index.html`
- Create: `prototype/css/style.css`

- [ ] **Step 1: 创建 package.json**

```json
{
  "name": "coursepet-prototype",
  "private": true,
  "type": "module"
}
```

- [ ] **Step 2: 创建 index.html**

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>课程表宠物</title>
<link rel="stylesheet" href="css/style.css">
<script src="https://cdn.sheetjs.com/xlsx-0.20.2/package/dist/xlsx.full.min.js"></script>
</head>
<body>
<header class="topbar">
  <button id="btn-prev-week" class="icon-btn" aria-label="上一周">‹</button>
  <div class="week-info">
    <h1 id="week-title">加载中…</h1>
    <button id="btn-this-week" class="mini-btn">回到本周</button>
  </div>
  <button id="btn-next-week" class="icon-btn" aria-label="下一周">›</button>
  <div class="spacer"></div>
  <button id="btn-import" class="pill-btn">＋ 导入课表</button>
  <button id="btn-feed" class="pill-btn">🍙 养成</button>
  <button id="btn-game" class="pill-btn">🎮 小游戏</button>
  <button id="btn-settings" class="icon-btn" aria-label="设置">⚙</button>
</header>
<div id="countdown-bar" class="countdown-bar hidden" role="status"></div>
<main id="week-grid" class="week-grid" aria-label="本周课表"></main>
<div id="pet-box" class="pet-box">
  <div id="pet-bubble" class="pet-bubble hidden"></div>
  <img id="pet-img" alt="宠物" draggable="false">
</div>
<div id="dialog-root"></div>
<div id="toast" class="toast hidden"></div>
<script type="module" src="js/main.js"></script>
</body>
</html>
```

- [ ] **Step 3: 创建 css/style.css（设计 token + 基础样式）**

```css
/* 设计 token：4px 间距系统 / 单一主色 / 三档阴影 / 统一圆角 */
:root {
  --bg: #F7F4EE; --bg-soft: #FFFFFF; --fg: #3A3A3A; --fg-dim: #8A8A8A;
  --primary: #FF9E7D; --primary-soft: #FFD9C9; --danger: #E86A6A;
  --radius: 12px;
  --shadow-hover: 0 2px 8px rgba(0,0,0,.08);
  --shadow-float: 0 8px 24px rgba(0,0,0,.16);
  --shadow-modal: 0 12px 40px rgba(0,0,0,.22);
  --font: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
}
html[data-theme="dark"] {
  --bg: #1E1E22; --bg-soft: #2A2A30; --fg: #EDEDED; --fg-dim: #9A9AA2;
  --primary: #FF9E7D; --primary-soft: #4A3830;
}
* { box-sizing: border-box; }
body { margin: 0; font-family: var(--font); background: var(--bg); color: var(--fg); min-height: 100vh; }

/* 顶栏 */
.topbar { display: flex; align-items: center; gap: 8px; padding: 12px 16px; position: sticky; top: 0; background: var(--bg); z-index: 10; }
.topbar .spacer { flex: 1; }
.week-info { text-align: center; }
.week-info h1 { margin: 0; font-size: 20px; }
.mini-btn { border: none; background: var(--primary-soft); color: var(--fg); border-radius: 8px; padding: 4px 10px; font-size: 12px; cursor: pointer; }
.mini-btn:hover { box-shadow: var(--shadow-hover); }
.icon-btn { width: 44px; height: 44px; border: none; border-radius: 12px; background: var(--bg-soft); color: var(--fg); font-size: 22px; cursor: pointer; }
.icon-btn:hover { box-shadow: var(--shadow-hover); }
.pill-btn { min-height: 44px; border: none; border-radius: 999px; padding: 0 16px; background: var(--primary); color: #fff; font-size: 14px; cursor: pointer; }
.pill-btn:hover { box-shadow: var(--shadow-hover); }
button:focus-visible { outline: 3px solid var(--primary); outline-offset: 2px; }

/* 倒计时条 */
.countdown-bar { margin: 0 16px 8px; padding: 10px 16px; border-radius: var(--radius); background: var(--primary-soft); font-size: 14px; text-align: center; }
.countdown-bar .time { font-weight: 700; font-variant-numeric: tabular-nums; }
.hidden { display: none !important; }

/* 周视图 */
.week-grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 8px; padding: 0 16px 120px; }
.day-col { background: var(--bg-soft); border-radius: var(--radius); padding: 8px; min-height: 160px; }
.day-col h2 { margin: 4px 0 8px; font-size: 14px; text-align: center; }
.day-col.today { outline: 2px solid var(--primary); }
.course-block { border-radius: 8px; padding: 8px; margin-bottom: 8px; font-size: 12px; line-height: 1.5; border-left: 4px solid rgba(0,0,0,.18); }
.course-block .course-name { font-weight: 700; font-size: 13px; }
.course-block .course-time { opacity: .8; font-variant-numeric: tabular-nums; }
.course-block.current { box-shadow: 0 0 0 3px var(--primary); animation: pulse 2s ease-in-out infinite; }
@keyframes pulse { 50% { box-shadow: 0 0 0 5px var(--primary-soft); } }

/* 宠物 */
.pet-box { position: fixed; right: 16px; bottom: 16px; width: 120px; height: 120px; z-index: 20; }
.pet-box img { width: 100%; height: 100%; cursor: pointer; filter: drop-shadow(0 4px 8px rgba(0,0,0,.18)); transition: transform .15s; }
.pet-box img:active { transform: scale(.92); }
.pet-bubble { position: absolute; bottom: 100%; left: 50%; transform: translateX(-50%); background: var(--bg-soft); border-radius: 12px; padding: 8px 12px; font-size: 13px; box-shadow: var(--shadow-float); white-space: nowrap; margin-bottom: 8px; }

/* 弹层 */
.dialog-overlay { position: fixed; inset: 0; background: rgba(0,0,0,.45); display: flex; align-items: center; justify-content: center; z-index: 30; padding: 16px; }
.dialog { background: var(--bg-soft); border-radius: 16px; box-shadow: var(--shadow-modal); width: min(560px, 100%); max-height: 86vh; overflow: auto; }
.dialog-head { display: flex; align-items: center; justify-content: space-between; padding: 16px 20px 0; }
.dialog-head h3 { margin: 0; font-size: 17px; }
.dialog-body { padding: 16px 20px 20px; }
.form-row { margin-bottom: 12px; }
.form-row label { display: block; font-size: 13px; color: var(--fg-dim); margin-bottom: 4px; }
.form-row input, .form-row select { width: 100%; min-height: 44px; border: 1px solid #ccc; border-radius: 8px; padding: 0 10px; font-size: 15px; background: var(--bg-soft); color: var(--fg); font-family: var(--font); }
.btn-row { display: flex; gap: 8px; justify-content: flex-end; margin-top: 16px; }
.btn { min-height: 44px; border: none; border-radius: 10px; padding: 0 18px; font-size: 14px; cursor: pointer; background: var(--bg); color: var(--fg); }
.btn:hover { box-shadow: var(--shadow-hover); }
.btn.primary { background: var(--primary); color: #fff; }
.btn:disabled { opacity: .5; cursor: not-allowed; }

/* toast */
.toast { position: fixed; top: 72px; left: 50%; transform: translateX(-50%); background: var(--fg); color: var(--bg-soft); padding: 10px 20px; border-radius: 999px; font-size: 14px; z-index: 50; box-shadow: var(--shadow-float); }

/* 响应式：小屏单列 */
@media (max-width: 700px) {
  .week-grid { grid-template-columns: 1fr; padding-bottom: 160px; }
  .topbar { flex-wrap: wrap; }
}
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }
```

- [ ] **Step 4: 启动本地服务器验证骨架**

Run（后台）: `cd /d/AI/CoursePet/prototype && python -m http.server 8000`
打开 http://localhost:8000 ，检查：页面无控制台报错、顶栏按钮齐全、深色样式变量已定义。SheetJS 未加载不影响骨架（离线时控制台会有 404，可接受，导入功能在 Task 9 用到）。

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/package.json prototype/index.html prototype/css/style.css && git commit -m "feat: 原型骨架（index.html + 设计token CSS）"
```

---

## Task 2: week.js 周数计算（TDD）

**Files:**
- Create: `prototype/tests/week.test.mjs`
- Create: `prototype/js/week.js`
- Create: `prototype/tests/run.mjs`

- [ ] **Step 1: 写失败测试**

`prototype/tests/week.test.mjs`：

```js
import assert from 'node:assert';
import { currentWeekNumber, weekParityOf, startOfDay, formatDate, MS_PER_DAY } from '../js/week.js';

// 以 2026-09-07（周一）为学期开始日
const d = (s) => new Date(s + 'T12:00:00');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-07')), 1, '开学当天=第1周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-13')), 1, '第6天仍是第1周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-14')), 2, '第7天进入第2周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-20')), 2, '第13天仍是第2周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-21')), 3, '第14天进入第3周');
assert.equal(currentWeekNumber('2026-09-07', d('2026-09-01')), null, '开学前返回 null');
assert.equal(currentWeekNumber('', new Date()), null, '无开始日返回 null');
assert.equal(weekParityOf(1), 'single');
assert.equal(weekParityOf(2), 'double');
assert.equal(weekParityOf(3), 'single');
assert.equal(formatDate(new Date(2026, 8, 7)), '2026-09-07');
const so = startOfDay(new Date(2026, 8, 7, 23, 59, 59));
assert.equal(so.getHours(), 0, 'startOfDay 归零时分秒');
assert.equal(MS_PER_DAY, 86400000);
console.log('✔ week.test');
```

`prototype/tests/run.mjs`：

```js
// 零依赖测试入口：node tests/run.mjs（在 prototype 目录下执行）
const files = ['week', 'schedule', 'pet-state', 'mapping', 'store'];
for (const f of files) {
  try {
    await import(`./${f}.test.mjs`);
  } catch (e) {
    console.error('✘ ' + f + '.test 失败');
    throw e;
  }
}
console.log('✔ 全部测试通过');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: FAIL，报错 `Cannot find module '../js/week.js'`

- [ ] **Step 3: 实现 week.js**

`prototype/js/week.js`：

```js
// 周数计算与单双周判定（纯逻辑，无 DOM 依赖）

export const MS_PER_DAY = 86400000;

export function startOfDay(dt) {
  return new Date(dt.getFullYear(), dt.getMonth(), dt.getDate());
}

export function formatDate(dt) {
  const p = (n) => String(n).padStart(2, '0');
  return `${dt.getFullYear()}-${p(dt.getMonth() + 1)}-${p(dt.getDate())}`;
}

/** 学期开始日 'YYYY-MM-DD' 到 now 是第几周；开学前/无开始日返回 null */
export function currentWeekNumber(startDateStr, now = new Date()) {
  const parts = String(startDateStr || '').split('-').map(Number);
  if (parts.length !== 3 || parts.some((n) => !Number.isFinite(n))) return null;
  const [y, m, d] = parts;
  const start = new Date(y, m - 1, d);
  const diffDays = Math.floor((startOfDay(now) - start) / MS_PER_DAY);
  return diffDays < 0 ? null : Math.floor(diffDays / 7) + 1;
}

export function weekParityOf(weekNumber) {
  return weekNumber % 2 === 1 ? 'single' : 'double';
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: 显示 `✔ week.test`，随后 `schedule.test.mjs` 不存在报错——先创建空占位文件 `tests/schedule.test.mjs`、`tests/pet-state.test.mjs`、`tests/mapping.test.mjs`、`tests/store.test.mjs`（内容仅 `console.log('✔ …')` 占位，后续任务填充）

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/week.js prototype/tests/ && git commit -m "feat: 周数计算与单双周判定（TDD）"
```

---

## Task 3: schedule.js 课程模型与当前/下一节（TDD）

**Files:**
- Create: `prototype/js/schedule.js`
- Modify: `prototype/tests/schedule.test.mjs`（替换占位内容）

- [ ] **Step 1: 写失败测试**

`prototype/tests/schedule.test.mjs`：

```js
import assert from 'node:assert';
import { createCourse, coursesForWeek, coursesForDay, currentAndNext, countdownText, timeToMinutes, isValidTime } from '../js/schedule.js';

const mk = (o) => createCourse(o);
const all = [
  mk({ name: '单周课', dayOfWeek: 1, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'single' }),
  mk({ name: '双周课', dayOfWeek: 1, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'double' }),
  mk({ name: '每周课', dayOfWeek: 2, startTime: '14:00', endTime: '15:40', startWeek: 3, endWeek: 8, weekParity: 'both' }),
  mk({ name: '跨午夜', dayOfWeek: 3, startTime: '22:00', endTime: '00:30', startWeek: 1, endWeek: 16, weekParity: 'both' }),
];

assert.equal(timeToMinutes('08:00'), 480);
assert.equal(timeToMinutes('9:05'), 545);
assert.equal(timeToMinutes('25:00'), null, '非法小时');
assert.equal(timeToMinutes('abc'), null);
assert.equal(isValidTime('23:59'), true);

assert.equal(coursesForWeek(all, 1).map((c) => c.name).join(','), '单周课,每周课,跨午夜', '第1周(单)：单周课+每周课');
assert.equal(coursesForWeek(all, 2).map((c) => c.name).join(','), '双周课,每周课,跨午夜', '第2周(双)：双周课+每周课');
assert.equal(coursesForWeek(all, 9).map((c) => c.name).join(','), '单周课,跨午夜', '第9周(单)：每周课已结束');

const monday = new Date(2026, 8, 7, 12, 0); // 2026-09-07 周一 12:00
assert.equal(coursesForDay(all, 1).length, 2);

// 当前/下一节：周一 09:00 正在上单周课，下一节双周课
let r = currentAndNext(all, new Date(2026, 8, 7, 9, 0));
assert.equal(r.current.name, '单周课');
assert.equal(r.next.name, '双周课');
assert.equal(r.next.startDate.getHours(), 10);

// 周一 12:30：上午课都结束，无下一节
r = currentAndNext(all, new Date(2026, 8, 7, 12, 30));
assert.equal(r.current, null);
assert.equal(r.next, null);

// 跨午夜：周三 23:00 是当前课（结束时间 00:30 在次日）
r = currentAndNext(all, new Date(2026, 8, 9, 23, 0)); // 2026-09-09 周三
assert.equal(r.current.name, '跨午夜');

// 周四 00:15：跨午夜课已结束（属于周三），无当前课
r = currentAndNext(all, new Date(2026, 8, 10, 0, 15)); // 周四
assert.equal(r.current, null);

// 周日 dayOfWeek=7 映射
const sunCourse = mk({ name: '周日课', dayOfWeek: 7, startTime: '09:00', endTime: '10:00', startWeek: 1, endWeek: 16 });
r = currentAndNext([sunCourse], new Date(2026, 8, 13, 9, 30)); // 2026-09-13 周日
assert.equal(r.current.name, '周日课');

// 倒计时文本
const target = new Date(2026, 8, 7, 10, 0, 0);
assert.equal(countdownText(target, new Date(2026, 8, 7, 9, 59, 30)), '00:00:30');
assert.equal(countdownText(target, new Date(2026, 8, 7, 11, 0, 0)), '00:00:00', '已过时间不出现负数');
console.log('✔ schedule.test');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: FAIL，`Cannot find module '../js/schedule.js'`

- [ ] **Step 3: 实现 schedule.js**

`prototype/js/schedule.js`：

```js
// 课程模型 / 周过滤 / 当前与下一节 / 倒计时（纯逻辑）
import { weekParityOf } from './week.js';

export const COURSE_COLORS = ['#FFD1C4', '#C4E3FF', '#C9F2D0', '#FFF3BF', '#E5D4FF', '#FFE0B8', '#CBEFE7'];

export function timeToMinutes(t) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(t).trim());
  if (!m) return null;
  const h = Number(m[1]), min = Number(m[2]);
  return h > 23 || min > 59 ? null : h * 60 + min;
}

export function isValidTime(t) { return timeToMinutes(t) !== null; }

export function createCourse(o) {
  return {
    id: o.id ?? (String(Date.now()) + Math.random().toString(36).slice(2, 7)),
    name: o.name,
    teacher: o.teacher || '',
    location: o.location || '',
    dayOfWeek: o.dayOfWeek,           // 1=周一 … 7=周日
    startTime: o.startTime,            // 'HH:mm'
    endTime: o.endTime,
    startWeek: o.startWeek ?? 1,
    endWeek: o.endWeek ?? 20,
    weekParity: o.weekParity || 'both', // single|double|both
    color: o.color || COURSE_COLORS[((o.dayOfWeek || 1) - 1) % COURSE_COLORS.length],
  };
}

export function coursesForWeek(courses, weekNumber) {
  const parity = weekParityOf(weekNumber);
  return courses.filter((c) =>
    c.startWeek <= weekNumber && c.endWeek >= weekNumber &&
    (c.weekParity === 'both' || c.weekParity === parity));
}

export function coursesForDay(courses, dayOfWeek) {
  return courses.filter((c) => c.dayOfWeek === dayOfWeek)
    .sort((a, b) => timeToMinutes(a.startTime) - timeToMinutes(b.startTime));
}

/** 当天日号换算：JS getDay() 0=周日 → 1=周一…7=周日 */
function todayDow(now) { const g = now.getDay(); return g === 0 ? 7 : g; }

export function currentAndNext(courses, now) {
  const dow = todayDow(now);
  const curMin = now.getHours() * 60 + now.getMinutes();
  const midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let current = null, next = null;
  for (const c of courses) {
    if (c.dayOfWeek !== dow) continue;
    const s = timeToMinutes(c.startTime), e = timeToMinutes(c.endTime);
    const crossMidnight = e <= s; // 跨午夜课
    if (s <= curMin && (crossMidnight || curMin < e)) {
      if (!current || s >= timeToMinutes(current.startTime)) current = c;
    }
    if (curMin < s && (!next || s < timeToMinutes(next.startTime))) next = c;
  }
  return {
    current,
    next: next
      ? { ...next, startDate: new Date(midnight.getTime() + timeToMinutes(next.startTime) * 60000) }
      : null,
  };
}

/** 倒计时文本 HH:MM:SS，已过则 00:00:00 */
export function countdownText(target, now = new Date()) {
  let diff = Math.max(0, target - now);
  const h = Math.floor(diff / 3600000); diff -= h * 3600000;
  const m = Math.floor(diff / 60000); diff -= m * 60000;
  const s = Math.floor(diff / 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(h)}:${p(m)}:${p(s)}`;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: `✔ week.test` `✔ schedule.test` 均通过

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/schedule.js prototype/tests/schedule.test.mjs && git commit -m "feat: 课程模型/周过滤/当前下一节/倒计时（TDD）"
```

---

## Task 4: pet-state.js 宠物状态机（TDD）

**Files:**
- Create: `prototype/js/pet-state.js`
- Modify: `prototype/tests/pet-state.test.mjs`（替换占位内容）

- [ ] **Step 1: 写失败测试**

`prototype/tests/pet-state.test.mjs`：

```js
import assert from 'node:assert';
import { decideAction, bubbleFor } from '../js/pet-state.js';
import { createCourse } from '../js/schedule.js';

const mk = (o) => createCourse(o);
const courses = [
  mk({ name: '数学', dayOfWeek: 1, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
  mk({ name: '英语', dayOfWeek: 1, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
];
const base = (o) => ({ now: new Date(2026, 8, 7, 12, 0), courses, lowBattery: false, charging: false, music: false, lastClickAt: null, ...o });
const rand = () => 0.5; // 固定随机源，保证可复现

assert.equal(decideAction(base({ charging: true }), rand).action, 'charge', '充电优先');
assert.equal(decideAction(base({ lowBattery: true }), rand).action, 'weak', '低电量次之');
assert.equal(decideAction(base({ music: true }), rand).action, 'listen', '音乐再次之');

// 点击 5 秒内 → 开心/兴奋（rand=0.5 恒为 happy 分支的确定值：<0.5 为 false → excite，需按实现断言）
const click = decideAction(base({ lastClickAt: new Date(2026, 8, 7, 12, 0, 1) }), () => 0.9);
assert.ok(['happy', 'excite'].includes(click.action), '点击触发挥发性动作');

// 课前 15 分钟内 → nervous（10:00 的课，当前 09:50）
const pre = decideAction(base({ now: new Date(2026, 8, 7, 9, 50) }), rand);
assert.equal(pre.action, 'nervous');

// 上课中 rand=0.9 → idle；rand=0.1 → sleep
assert.equal(decideAction(base({ now: new Date(2026, 8, 7, 8, 30) }), () => 0.9).action, 'idle');
assert.equal(decideAction(base({ now: new Date(2026, 8, 7, 8, 30) }), () => 0.1).action, 'sleep');

// 课后 10 分钟内 → walk/excite
const after = decideAction(base({ now: new Date(2026, 8, 7, 9, 45) }), () => 0.9);
assert.ok(['walk', 'excite'].includes(after.action), '课后10分钟内为活跃动作');

// 课间平静期 → idle
assert.equal(decideAction(base({ now: new Date(2026, 8, 7, 12, 0) }), rand).action, 'idle');

// 气泡按心情分段
assert.ok(bubbleFor(90, () => 0).length > 0);
assert.ok(bubbleFor(20, () => 0).length > 0);
assert.ok(bubbleFor(50, () => 0).length > 0);
console.log('✔ pet-state.test');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: FAIL，`Cannot find module '../js/pet-state.js'`

- [ ] **Step 3: 实现 pet-state.js**

`prototype/js/pet-state.js`：

```js
// 宠物状态机：输入（时间+课程+系统状态+互动）→ 输出动作与气泡（纯逻辑）
import { currentAndNext, timeToMinutes } from './schedule.js';

export const CLICK_BUBBLES = ['嘿嘿，找我玩吗？', '今天也要加油鸭！', '最喜欢你啦～', '好无聊，陪我玩一会儿嘛'];

export function bubbleFor(mood, rand = Math.random) {
  const pick = (arr) => arr[Math.floor(rand() * arr.length)];
  if (mood >= 80) return pick(['今天状态满分！', '有你在真好～', '冲鸭！']);
  if (mood <= 30) return pick(['好饿…想被投喂', '没什么精神…', '陪我玩一会儿嘛']);
  return pick(['下节课在哪栋楼？', '今天也要加油鸭', '好困啊…']);
}

/** ctx: {now, courses, charging, lowBattery, music, lastClickAt}；rand 可注入便于测试 */
export function decideAction(ctx, rand = Math.random) {
  const { now, courses } = ctx;
  if (ctx.charging) return { action: 'charge', bubble: '充得满满哒～' };
  if (ctx.lowBattery) return { action: 'weak', bubble: '电量告急，帮我充个电吧…' };
  if (ctx.music) return { action: 'listen', bubble: '' };
  if (ctx.lastClickAt && now - ctx.lastClickAt < 5000) {
    return { action: rand() < 0.5 ? 'happy' : 'excite', bubble: CLICK_BUBBLES[Math.floor(rand() * CLICK_BUBBLES.length)] };
  }
  const { current, next } = currentAndNext(courses, now);
  if (next && (next.startDate - now) / 60000 <= 15) {
    return { action: 'nervous', bubble: '下节课要迟到了！' };
  }
  if (current) {
    return rand() < 0.2 ? { action: 'sleep', bubble: 'zzZ…' } : { action: 'idle', bubble: '' };
  }
  // 课后 10 分钟内 → 活跃
  const curMin = now.getHours() * 60 + now.getMinutes();
  const dow = now.getDay() === 0 ? 7 : now.getDay();
  const ended = courses
    .filter((c) => c.dayOfWeek === dow && timeToMinutes(c.endTime) <= curMin)
    .sort((a, b) => timeToMinutes(b.endTime) - timeToMinutes(a.endTime));
  if (ended.length && curMin - timeToMinutes(ended[0].endTime) <= 10) {
    return { action: rand() < 0.5 ? 'walk' : 'excite', bubble: '下课啦！' };
  }
  return { action: 'idle', bubble: '' };
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: `✔ pet-state.test` 通过

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/pet-state.js prototype/tests/pet-state.test.mjs && git commit -m "feat: 宠物状态机（TDD）"
```

---

## Task 5: mapping.js 字段映射与行解析（TDD）

**Files:**
- Create: `prototype/js/mapping.js`
- Modify: `prototype/tests/mapping.test.mjs`（替换占位内容）

- [ ] **Step 1: 写失败测试**

`prototype/tests/mapping.test.mjs`：

```js
import assert from 'node:assert';
import { guessMapping, mapRows, normalizeDayOfWeek, normalizeParity, normalizeWeek } from '../js/mapping.js';

const header = ['课程名称', '教师', '地点', '星期', '开始时间', '结束时间', '起始周', '结束周', '单双周'];
const fm = guessMapping(header);
assert.equal(fm.name, 0);
assert.equal(fm.teacher, 1);
assert.equal(fm.location, 2);
assert.equal(fm.dayOfWeek, 3);
assert.equal(fm.startTime, 4);
assert.equal(fm.endTime, 5);
assert.equal(fm.startWeek, 6);
assert.equal(fm.endWeek, 7);
assert.equal(fm.weekParity, 8);

// 表头完全对不上时返回 -1
assert.equal(guessMapping(['A', 'B', 'C']).name, -1);

assert.equal(normalizeDayOfWeek('1'), 1);
assert.equal(normalizeDayOfWeek('星期一'), 1);
assert.equal(normalizeDayOfWeek('周三'), 3);
assert.equal(normalizeDayOfWeek('日'), 7);
assert.equal(normalizeDayOfWeek('星期天'), 7);
assert.equal(normalizeDayOfWeek('x'), null);

assert.equal(normalizeParity('单'), 'single');
assert.equal(normalizeParity('双'), 'double');
assert.equal(normalizeParity('单双'), 'both');
assert.equal(normalizeParity('每周'), 'both');
assert.equal(normalizeWeek('3'), 3);
assert.equal(normalizeWeek('abc'), null);

const rows = [
  header,
  ['高等数学', '张老师', '教1-201', '一', '08:00', '09:40', 1, 16, '单双'],
  ['', '李老师', '外语楼', '二', '10:00', '11:40', 1, 16, '单'],       // 空行（名称空）→ 计入 errors
  ['大学英语', '', '', '三', '9:00', '9:59', 2, 3, '双'],
  ['坏时间课', '', '', '四', '99:00', '10:00', 1, 16, '单'],           // 时间非法 → errors
];
const { courses, errors } = mapRows(rows, fm);
assert.equal(courses.length, 2, '两条合法课程');
assert.equal(courses[0].name, '高等数学');
assert.equal(courses[0].dayOfWeek, 1);
assert.equal(courses[0].weekParity, 'both');
assert.equal(courses[1].startWeek, 2);
assert.equal(errors.length, 2, '两条错误行被报告');
assert.equal(errors[0].row, 3, '错误行号（含表头）');
console.log('✔ mapping.test');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: FAIL，`Cannot find module '../js/mapping.js'`

- [ ] **Step 3: 实现 mapping.js**

`prototype/js/mapping.js`：

```js
// Excel 行数据 → 课程对象：表头自动猜测 + 手动映射 + 逐行校验（纯逻辑）
import { createCourse, timeToMinutes } from './schedule.js';

const KEYWORDS = {
  name: ['课程', '名称', '课名'],
  teacher: ['教师', '老师', '授课'],
  location: ['地点', '教室', '位置'],
  dayOfWeek: ['星期', '周几'],
  startTime: ['开始时间', '上课时间', '开始'],
  endTime: ['结束时间', '下课时间', '结束'],
  startWeek: ['起始周', '开始周', '起始'],
  endWeek: ['结束周', '终止周', '截止'],
  weekParity: ['单双', '周型', '周次类型'],
};

/** 按关键字猜测表头列，匹配不到为 -1 */
export function guessMapping(headerRow) {
  const fm = {};
  for (const [field, kws] of Object.entries(KEYWORDS)) {
    fm[field] = headerRow.findIndex((h) => kws.some((k) => String(h).includes(k)));
  }
  return fm;
}

export function normalizeDayOfWeek(v) {
  const s = String(v ?? '').trim();
  if (/^[1-7]$/.test(s)) return Number(s);
  const map = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7 };
  for (const [ch, n] of Object.entries(map)) {
    if (s.includes(ch)) return n;
  }
  return null;
}

export function normalizeParity(v) {
  const s = String(v ?? '');
  if (s.includes('双') && s.includes('单')) return 'both';
  if (s.includes('双')) return 'double';
  if (s.includes('单')) return 'single';
  return 'both';
}

export function normalizeWeek(v) {
  const n = parseInt(String(v), 10);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * rows: SheetJS sheet_to_json(ws, {header:1}) 的输出（首行为表头）
 * fm: {name, teacher, location, dayOfWeek, startTime, endTime, startWeek, endWeek, weekParity} → 列号（-1 缺省）
 * 返回 {courses, errors:[{row, reason}]}，空行跳过，坏行不阻断整体
 */
export function mapRows(rows, fm) {
  const courses = [], errors = [];
  const col = (row, field) => (fm[field] != null && fm[field] >= 0 ? row[fm[field]] : undefined);
  for (let i = 1; i < rows.length; i++) {
    const row = rows[i], rowNo = i + 1;
    if (!row || row.every((c) => c === undefined || c === null || String(c).trim() === '')) continue;
    const name = String(col(row, 'name') ?? '').trim();
    const dow = normalizeDayOfWeek(col(row, 'dayOfWeek'));
    const startTime = String(col(row, 'startTime') ?? '').trim();
    const endTime = String(col(row, 'endTime') ?? '').trim();
    if (!name) { errors.push({ row: rowNo, reason: '缺少课程名称' }); continue; }
    if (!dow) { errors.push({ row: rowNo, reason: `星期几无法识别（${String(col(row, 'dayOfWeek') ?? '').trim() || '空'}）` }); continue; }
    if (!timeToMinutes(startTime)) { errors.push({ row: rowNo, reason: '开始时间格式不对（应为 HH:mm）' }); continue; }
    if (!timeToMinutes(endTime)) { errors.push({ row: rowNo, reason: '结束时间格式不对（应为 HH:mm）' }); continue; }
    const startWeek = normalizeWeek(col(row, 'startWeek')) ?? 1;
    const endWeek = normalizeWeek(col(row, 'endWeek')) ?? 20;
    if (endWeek < startWeek) { errors.push({ row: rowNo, reason: '结束周小于起始周' }); continue; }
    courses.push(createCourse({
      name,
      teacher: String(col(row, 'teacher') ?? '').trim(),
      location: String(col(row, 'location') ?? '').trim(),
      dayOfWeek: dow, startTime, endTime, startWeek, endWeek,
      weekParity: normalizeParity(col(row, 'weekParity')),
    }));
  }
  return { courses, errors };
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: `✔ mapping.test` 通过

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/mapping.js prototype/tests/mapping.test.mjs && git commit -m "feat: Excel 字段映射与行解析（TDD）"
```

---

## Task 6: store.js 存储层 + demo-data.js（TDD）

**Files:**
- Create: `prototype/js/store.js`
- Create: `prototype/js/demo-data.js`
- Modify: `prototype/tests/store.test.mjs`（替换占位内容）

- [ ] **Step 1: 写失败测试**

`prototype/tests/store.test.mjs`：

```js
import assert from 'node:assert';
import { createStore, mergeDefaults, DEFAULT_STATE } from '../js/store.js';
import { demoCourses } from '../js/demo-data.js';

// 内存假 storage，模拟 localStorage
function memStorage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v), _m: m };
}

const s1 = memStorage();
const store = createStore(s1);
const state = store.load();
assert.equal(state.pet.name, '小火人', '默认宠物名');
assert.equal(state.settings.animSpeed, 'mid');
assert.deepEqual(state.courses, []);
store.save({ ...state, pet: { ...state.pet, food: 3 } });
const state2 = createStore(memStorage()).load();
assert.equal(state2.pet.food, 5, '新 storage 读不到旧数据');

const loaded = createStore(s1).load();
assert.equal(loaded.pet.food, 3, '保存后能读回');
assert.equal(loaded.settings.charId, 'char1', '未保存的字段用默认值补全');

// 损坏 JSON 不崩
const bad = memStorage();
bad.setItem('coursepet', '{oops');
assert.equal(createStore(bad).load().pet.name, '小火人');

// 演示数据：7 条课程、字段完整
const demo = demoCourses();
assert.equal(demo.length, 7);
assert.ok(demo.every((c) => c.name && c.dayOfWeek >= 1 && c.dayOfWeek <= 7 && c.startTime < c.endTime));
assert.ok(demo.some((c) => c.weekParity === 'single') && demo.some((c) => c.weekParity === 'double'));
console.log('✔ store.test');
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: FAIL，`Cannot find module '../js/store.js'`

- [ ] **Step 3: 实现 store.js 与 demo-data.js**

`prototype/js/store.js`：

```js
// localStorage 持久化（storage 可注入，便于测试）
export const DEFAULT_STATE = {
  version: 1,
  semester: { startDate: '' },   // 'YYYY-MM-DD'
  courses: [],
  pet: { name: '小火人', mood: 70, affection: 0, food: 5 },
  settings: {
    animSpeed: 'mid',            // slow|mid|fast
    simLowBattery: false, simCharging: false, simMusic: false, // 原型期模拟开关
    darkMode: false,
    charId: 'char1',             // pet_assets 下的角色目录
  },
};

export function mergeDefaults(s) {
  return {
    ...DEFAULT_STATE, ...s,
    semester: { ...DEFAULT_STATE.semester, ...(s.semester || {}) },
    pet: { ...DEFAULT_STATE.pet, ...(s.pet || {}) },
    settings: { ...DEFAULT_STATE.settings, ...(s.settings || {}) },
  };
}

export function createStore(storage) {
  return {
    load() {
      try {
        const raw = storage.getItem('coursepet');
        return raw ? mergeDefaults(JSON.parse(raw)) : mergeDefaults({});
      } catch (e) {
        return mergeDefaults({});
      }
    },
    save(state) { storage.setItem('coursepet', JSON.stringify(state)); },
  };
}
```

`prototype/js/demo-data.js`：

```js
// 内置示例课表：学期开始当天为第 1 周（单周），覆盖单/双/每周三种 parity
import { createCourse } from './schedule.js';

export function demoCourses() {
  const mk = (o) => createCourse(o);
  return [
    mk({ name: '高等数学', teacher: '张老师', location: '教1-201', dayOfWeek: 1, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
    mk({ name: '大学英语', teacher: '李老师', location: '外语楼305', dayOfWeek: 1, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'single' }),
    mk({ name: '体育', location: '操场', dayOfWeek: 2, startTime: '14:00', endTime: '15:40', startWeek: 1, endWeek: 16, weekParity: 'double' }),
    mk({ name: '信号与系统', teacher: '王老师', location: '教2-508', dayOfWeek: 3, startTime: '08:00', endTime: '09:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
    mk({ name: '数据结构', teacher: '陈老师', location: '实验楼B204', dayOfWeek: 3, startTime: '14:00', endTime: '15:40', startWeek: 1, endWeek: 16, weekParity: 'single' }),
    mk({ name: '马克思主义原理', location: '教3-101', dayOfWeek: 4, startTime: '10:00', endTime: '11:40', startWeek: 1, endWeek: 16, weekParity: 'both' }),
    mk({ name: 'Python 程序设计', teacher: '刘老师', location: '机房302', dayOfWeek: 5, startTime: '14:00', endTime: '15:40', startWeek: 1, endWeek: 16, weekParity: 'double' }),
  ];
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: `✔ store.test` 通过，且 `✔ 全部测试通过`

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/store.js prototype/js/demo-data.js prototype/tests/store.test.mjs && git commit -m "feat: 存储层与演示课表数据（TDD）"
```

---

## Task 7: 主界面装配（周视图 + 倒计时 + main.js）

**Files:**
- Create: `prototype/js/ui/week-view.js`
- Create: `prototype/js/main.js`

- [ ] **Step 1: 实现 week-view.js**

`prototype/js/ui/week-view.js`：

```js
// 周视图渲染 + 倒计时条
import { coursesForDay, currentAndNext, countdownText } from '../schedule.js';

const DAY_NAMES = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (ch) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

export function renderWeek(gridEl, courses, now) {
  const { current } = currentAndNext(courses, now);
  const dow = now.getDay() === 0 ? 7 : now.getDay();
  gridEl.innerHTML = '';
  for (let d = 1; d <= 7; d++) {
    const col = document.createElement('section');
    col.className = 'day-col' + (d === dow ? ' today' : '');
    const head = document.createElement('h2');
    head.textContent = DAY_NAMES[d - 1];
    col.appendChild(head);
    for (const c of coursesForDay(courses, d)) {
      const block = document.createElement('div');
      block.className = 'course-block';
      block.style.background = c.color;
      if (current && current.id === c.id) block.classList.add('current');
      const name = document.createElement('div');
      name.className = 'course-name';
      name.textContent = c.name;
      const time = document.createElement('div');
      time.className = 'course-time';
      time.textContent = `${c.startTime}–${c.endTime}`;
      const loc = document.createElement('div');
      loc.className = 'course-loc';
      loc.textContent = c.location || c.teacher || '';
      block.append(name, time, loc);
      col.appendChild(block);
    }
    gridEl.appendChild(col);
  }
}

/** 顶部倒计时条：上课中→剩余时间；课前→距上课时间；无课→隐藏 */
export function updateCountdown(barEl, courses, now) {
  const { current, next } = currentAndNext(courses, now);
  if (current) {
    const end = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
      +current.endTime.split(':')[0], +current.endTime.split(':')[1]);
    const endMs = current.endTime <= current.startTime ? end.getTime() + 86400000 : end.getTime();
    barEl.innerHTML = `正在上「${escapeHtml(current.name)}」，剩余 <span class="time">${countdownText(endMs, now)}</span>`;
    barEl.classList.remove('hidden');
  } else if (next) {
    barEl.innerHTML = `距「${escapeHtml(next.name)}」上课 <span class="time">${countdownText(next.startDate, now)}</span>`;
    barEl.classList.remove('hidden');
  } else {
    barEl.classList.add('hidden');
  }
}
```

- [ ] **Step 2: 实现 main.js（装配所有模块）**

`prototype/js/main.js`：

```js
// 装配入口：store + 状态机 + 周视图 + 倒计时定时器
import { createStore } from './store.js';
import { currentWeekNumber, weekParityOf, formatDate } from './week.js';
import { coursesForWeek } from './schedule.js';
import { demoCourses } from './demo-data.js';
import { renderWeek, updateCountdown } from './ui/week-view.js';

const store = createStore(localStorage);
let state = store.load();

// 首次使用：学期开始日设为今天 + 演示课表
if (!state.semester.startDate) {
  state.semester.startDate = formatDate(new Date());
  state.courses = demoCourses();
  store.save(state);
}

const weekTitle = document.getElementById('week-title');
const weekGrid = document.getElementById('week-grid');
const countdownBar = document.getElementById('countdown-bar');
const btnPrev = document.getElementById('btn-prev-week');
const btnNext = document.getElementById('btn-next-week');
const btnThis = document.getElementById('btn-this-week');

let viewingWeek = currentWeekNumber(state.semester.startDate) || 1;

function render() {
  const weekNumber = currentWeekNumber(state.semester.startDate);
  const parity = weekParityOf(viewingWeek);
  const prefix = viewingWeek === weekNumber ? '' : '（查看中）';
  weekTitle.textContent = `第 ${viewingWeek} 周 · ${parity === 'single' ? '单周' : '双周'}${prefix}`;
  const now = new Date();
  renderWeek(weekGrid, coursesForWeek(state.courses, viewingWeek), viewingWeek === weekNumber ? now : new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59));
  updateCountdown(countdownBar, coursesForWeek(state.courses, weekNumber), now);
}

btnPrev.addEventListener('click', () => { viewingWeek = Math.max(1, viewingWeek - 1); render(); });
btnNext.addEventListener('click', () => { viewingWeek += 1; render(); });
btnThis.addEventListener('click', () => { viewingWeek = currentWeekNumber(state.semester.startDate) || 1; render(); });

setInterval(() => updateCountdown(countdownBar, coursesForWeek(state.courses, currentWeekNumber(state.semester.startDate) || 1), new Date()), 1000);
render();
```

- [ ] **Step 3: 手动验证**

Run: `cd /d/AI/CoursePet/prototype && python -m http.server 8000`（若未运行）
打开 http://localhost:8000 ，检查：
- [ ] 标题显示「第 1 周 · 单周」（今天是 2026-09-07，学期开始日=今天）
- [ ] 周一到周日 7 列，课程块显示名称/时间/地点，颜色柔和
- [ ] 「‹」「›」切换周数，「回到本周」复位；第 2 周显示双周课（体育/Python），第 1 周显示单周课（英语/数据结构）
- [ ] 倒计时条：若当前有课显示剩余时间并每秒跳动；无课显示距下节课时间；无任何课时隐藏
- [ ] 今天所在列有高亮描边
- [ ] 刷新页面数据仍在（localStorage）

- [ ] **Step 4: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/ui/week-view.js prototype/js/main.js && git commit -m "feat: 主界面装配（周视图+倒计时+演示数据）"
```

---

## Task 8: 宠物区（帧动画播放器 + 点击互动 + 气泡）

**Files:**
- Create: `prototype/js/ui/dialogs.js`
- Create: `prototype/js/ui/pet.js`
- Modify: `prototype/js/main.js`（接入宠物）

- [ ] **Step 1: 实现 dialogs.js**

`prototype/js/ui/dialogs.js`：

```js
// 通用弹层 + toast
export function openDialog(title, bodyEl, opts = {}) {
  const root = document.getElementById('dialog-root');
  const overlay = document.createElement('div');
  overlay.className = 'dialog-overlay';
  const box = document.createElement('div');
  box.className = 'dialog';
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-label', title);
  const head = document.createElement('div');
  head.className = 'dialog-head';
  const h = document.createElement('h3');
  h.textContent = title;
  const close = document.createElement('button');
  close.className = 'icon-btn';
  close.textContent = '✕';
  close.setAttribute('aria-label', '关闭');
  let onCloseCb = opts.onClose || null;
  const doClose = () => { overlay.remove(); if (onCloseCb) onCloseCb(); };
  close.addEventListener('click', doClose);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) doClose(); });
  head.append(h, close);
  box.append(head, bodyEl);
  overlay.append(box);
  root.append(overlay);
  return { overlay, box, close: doClose, setOnClose: (fn) => { onCloseCb = fn; } };
}

let toastTimer = null;
export function toast(text) {
  const el = document.getElementById('toast');
  el.textContent = text;
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), 2500);
}
```

- [ ] **Step 2: 实现 pet.js**

`prototype/js/ui/pet.js`：

```js
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

  return { play, showBubble, getAction: () => action };
}
```

- [ ] **Step 3: 修改 main.js 接入宠物**

在 `prototype/js/main.js` 顶部 import 区追加：

```js
import { initPet } from './ui/pet.js';
import { decideAction, bubbleFor } from './pet-state.js';
```

在 `render()` 函数定义之后追加：

```js
const petImg = document.getElementById('pet-img');
const petBubble = document.getElementById('pet-bubble');
let lastClickAt = null;
const pet = initPet(petImg, petBubble, {
  getCharId: () => state.settings.charId,
  getSpeed: () => state.settings.animSpeed,
  onClick: () => { lastClickAt = new Date(); refreshPet(); },
});

function refreshPet() {
  const ctx = {
    now: new Date(),
    courses: coursesForWeek(state.courses, currentWeekNumber(state.semester.startDate) || 1),
    charging: state.settings.simCharging,
    lowBattery: state.settings.simLowBattery,
    music: state.settings.simMusic,
    lastClickAt,
  };
  const r = decideAction(ctx);
  if (r.action !== pet.getAction()) pet.play(r.action);
  if (r.bubble) pet.showBubble(r.bubble);
  else if (Math.random() < 0.3) pet.showBubble(bubbleFor(state.pet.mood));
}
setInterval(refreshPet, 30000);
refreshPet();
```

- [ ] **Step 4: 手动验证**

打开 http://localhost:8000 ，检查：
- [ ] 右下角宠物出现（char1 小火人），待机呼吸动画循环
- [ ] 点击宠物：随机播开心/兴奋动画一遍后回待机，手机端有震动，气泡出现 4 秒后消失
- [ ] 打开设置（本任务设置弹层还没做，验证放 Task 11）——本任务先确认无控制台报错

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/ui/dialogs.js prototype/js/ui/pet.js prototype/js/main.js && git commit -m "feat: 宠物帧动画播放器+点击互动+气泡"
```

---

## Task 9: 导入流程（选文件→解析→映射→预览→入库）+ 示例 xlsx

**Files:**
- Create: `prototype/tools/make_sample_xlsx.py`（放 prototype/tools/）
- Create: `prototype/js/ui/import.js`
- Modify: `prototype/js/main.js`（接入导入）

- [ ] **Step 1: 生成示例 xlsx**

`prototype/tools/make_sample_xlsx.py`：

```python
# 生成示例课表 xlsx（零依赖，仅标准库 zipfile + 手写最小 OOXML）
import os, zipfile

OUT = os.path.join(os.path.dirname(__file__), '..', 'sample_files')
os.makedirs(OUT, exist_ok=True)

def esc(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

rows = [
    ['课程名称', '教师', '地点', '星期', '开始时间', '结束时间', '起始周', '结束周', '单双周'],
    ['高等数学', '张老师', '教1-201', '一', '08:00', '09:40', 1, 16, '单双'],
    ['大学英语', '李老师', '外语楼305', '一', '10:00', '11:40', 1, 16, '单'],
    ['体育', '', '操场', '二', '14:00', '15:40', 1, 16, '双'],
    ['信号与系统', '王老师', '教2-508', '三', '08:00', '09:40', 1, 16, '单双'],
    ['数据结构', '陈老师', '实验楼B204', '三', '14:00', '15:40', 1, 16, '单'],
    ['马克思主义原理', '', '教3-101', '四', '10:00', '11:40', 1, 16, '单双'],
    ['Python 程序设计', '刘老师', '机房302', '五', '14:00', '15:40', 1, 16, '双'],
]

def sheet_xml():
    rows_xml = []
    for r, row in enumerate(rows, 1):
        cells = []
        for c, v in enumerate(row, 1):
            ref = f'{chr(64 + c)}{r}'
            if isinstance(v, (int, float)):
                cells.append(f'<c r="{ref}"><v>{v}</v></c>')
            else:
                cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{esc(v)}</t></is></c>')
        rows_xml.append(f'<row r="{r}">{"".join(cells)}</row>')
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetData>' + ''.join(rows_xml) + '</sheetData></worksheet>')

files = {
    '[Content_Types].xml': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '</Types>'),
    '_rels/.rels': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'),
    'xl/workbook.xml': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="课表" sheetId="1" r:id="rId1"/></sheets></workbook>'),
    'xl/_rels/workbook.xml.rels': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '</Relationships>'),
    'xl/worksheets/sheet1.xml': sheet_xml(),
}

path = os.path.join(OUT, '课表示例.xlsx')
with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
    for name, content in files.items():
        z.writestr(name, content)
print('written', path)
```

Run: `python prototype/tools/make_sample_xlsx.py`
Expected: `written D:\AI\CoursePet\prototype\sample_files\课表示例.xlsx`

- [ ] **Step 2: 实现 import.js**

`prototype/js/ui/import.js`：

```js
// 导入流程：选文件 → SheetJS 解析 → 字段映射 → 预览 → 入库
import { guessMapping, mapRows } from '../mapping.js';
import { openDialog, toast } from './dialogs.js';
import { escapeHtml } from './week-view.js';

const FIELDS = [
  ['name', '课程名称（必填）'],
  ['teacher', '教师（可选）'],
  ['location', '地点（可选）'],
  ['dayOfWeek', '星期几（必填）'],
  ['startTime', '开始时间（必填）'],
  ['endTime', '结束时间（必填）'],
  ['startWeek', '起始周（可选，默认1）'],
  ['endWeek', '结束周（可选，默认20）'],
  ['weekParity', '单双周（可选，默认每周）'],
];

async function parseFile(file) {
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array' });   // SheetJS 由 index.html 的 CDN script 提供
  const ws = wb.Sheets[wb.SheetNames[0]];
  if (!ws) throw new Error('Excel 里没有工作表');
  return XLSX.utils.sheet_to_json(ws, { header: 1, defval: '' });
}

export function initImport({ onImport }) {
  document.getElementById('btn-import').addEventListener('click', () => {
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <p style="margin-top:0;font-size:14px">支持 .xlsx / .xls。单双周分开两个文件时：导入单周文件选「单周」、双周文件选「双周」；只有一个通用文件选「自动」。</p>
      <div class="form-row"><label for="import-file">课表文件</label>
        <input id="import-file" type="file" accept=".xlsx,.xls"></div>
      <div class="form-row"><label for="import-parity">单双周归属</label>
        <select id="import-parity">
          <option value="">自动（按文件里的单双周列）</option>
          <option value="single">这是单周课表</option>
          <option value="double">这是双周课表</option>
        </select></div>
      <div id="import-mapping" class="hidden"></div>
      <div id="import-preview" class="hidden"></div>
      <div class="btn-row">
        <button id="import-cancel" class="btn">取消</button>
        <button id="import-confirm" class="btn primary" disabled>确认导入</button>
      </div>`;
    const dlg = openDialog('导入课表', body);
    const fileInput = body.querySelector('#import-file');
    const paritySel = body.querySelector('#import-parity');
    const mappingBox = body.querySelector('#import-mapping');
    const previewBox = body.querySelector('#import-preview');
    const confirmBtn = body.querySelector('#import-confirm');
    body.querySelector('#import-cancel').addEventListener('click', dlg.close);

    let fm = null, rows = null, parsed = null;

    fileInput.addEventListener('change', async () => {
      const file = fileInput.files[0];
      if (!file) return;
      try {
        rows = await parseFile(file);
      } catch (e) {
        toast('文件解析失败：' + e.message);
        return;
      }
      if (!rows.length) { toast('文件是空的'); return; }
      fm = guessMapping(rows[0]);
      mappingBox.innerHTML = '<h4 style="margin:12px 0 8px">字段映射（对不上的列手动选）</h4>';
      mappingBox.classList.remove('hidden');
      const selects = {};
      for (const [field, label] of FIELDS) {
        const row = document.createElement('div');
        row.className = 'form-row';
        const lab = document.createElement('label');
        lab.textContent = label;
        const sel = document.createElement('select');
        sel.dataset.field = field;
        sel.innerHTML = '<option value="-1">— 不导入 —</option>' +
          rows[0].map((h, i) => `<option value="${i}">第 ${i + 1} 列：${escapeHtml(String(h).slice(0, 12))}</option>`).join('');
        sel.value = String(fm[field] ?? -1);
        selects[field] = sel;
        row.append(lab, sel);
        mappingBox.append(row);
      }
      const apply = () => {
        for (const [field, sel] of Object.entries(selects)) fm[field] = Number(sel.value);
        parsed = mapRows(rows, fm);
        const parity = paritySel.value;
        if (parity) parsed.courses.forEach((c) => { c.weekParity = parity; });
        previewBox.innerHTML = `
          <h4 style="margin:12px 0 8px">预览（共 ${parsed.courses.length} 条课程）</h4>
          <div style="max-height:180px;overflow:auto;font-size:13px;border:1px solid #ddd;border-radius:8px;">
            <table style="width:100%;border-collapse:collapse">
              <tr><th style="padding:6px;text-align:left">课程</th><th>星期</th><th>时间</th><th>周次</th></tr>
              ${parsed.courses.slice(0, 10).map((c) => `<tr><td style="padding:6px">${escapeHtml(c.name)}</td><td>${c.dayOfWeek}</td><td>${c.startTime}–${c.endTime}</td><td>${c.startWeek}-${c.endWeek}周</td></tr>`).join('')}
            </table>
          </div>
          ${parsed.errors.length ? `<p style="color:var(--danger);font-size:13px">⚠ ${parsed.errors.length} 行无法导入：${parsed.errors.slice(0, 3).map((e) => `第${e.row}行 ${e.reason}`).join('；')}</p>` : ''}`;
        previewBox.classList.remove('hidden');
        confirmBtn.disabled = parsed.courses.length === 0;
      };
      mappingBox.addEventListener('change', apply);
      paritySel.addEventListener('change', apply);
      apply();
    });

    confirmBtn.addEventListener('click', () => {
      if (!parsed) return;
      onImport(parsed.courses);
      toast(`已导入 ${parsed.courses.length} 条课程`);
      dlg.close();
    });
  });
}
```

- [ ] **Step 3: 修改 main.js 接入导入**

在 `prototype/js/main.js` import 区追加：

```js
import { initImport } from './ui/import.js';
```

在 `render()` 调用之后追加：

```js
initImport({
  onImport: (courses) => {
    state.courses = state.courses.concat(courses); // 追加；清空走设置里的「清空全部数据」
    store.save(state);
    render();
    refreshPet();
  },
});
```

- [ ] **Step 4: 手动验证**

打开 http://localhost:8000 （需联网加载 SheetJS CDN），检查：
- [ ] 点「＋ 导入课表」→ 选择 `sample_files/课表示例.xlsx` → 字段映射自动猜中（课程名称/星期/开始时间…）→ 预览 7 条 → 确认导入 → toast 提示
- [ ] 新课程与演示课表同时出现在网格（追加模式）
- [ ] 选「单周」归属再导一次：预览里单双周被覆盖为单周

- [ ] **Step 5: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/tools/make_sample_xlsx.py prototype/sample_files/ prototype/js/ui/import.js prototype/js/main.js && git commit -m "feat: Excel 导入流程（映射+预览）+示例xlsx生成器"
```

---

## Task 10: 养成面板（喂食/打卡）

**Files:**
- Create: `prototype/js/ui/feed.js`
- Modify: `prototype/js/main.js`（接入养成 + 心情随时间衰减）

- [ ] **Step 1: 实现 feed.js**

`prototype/js/ui/feed.js`：

```js
// 养成面板：心情/好感度/食物 + 喂食 + 上课打卡
import { openDialog, toast } from './dialogs.js';
import { coursesForWeek, currentAndNext } from '../schedule.js';
import { currentWeekNumber } from '../week.js';

export function initFeed({ getState, save }) {
  document.getElementById('btn-feed').addEventListener('click', () => {
    const st = getState();
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <div style="display:flex;gap:20px;justify-content:center;margin:8px 0 16px">
        <div style="text-align:center"><div id="feed-mood" style="font-size:30px">–</div><div style="font-size:12px;color:var(--fg-dim)">心情</div></div>
        <div style="text-align:center"><div id="feed-aff" style="font-size:30px">–</div><div style="font-size:12px;color:var(--fg-dim)">好感度</div></div>
        <div style="text-align:center"><div id="feed-food" style="font-size:30px">–</div><div style="font-size:12px;color:var(--fg-dim)">食物</div></div>
      </div>
      <p style="font-size:13px;color:var(--fg-dim);text-align:center">上课时来打卡获得食物；食物可喂给宠物提升心情和好感度</p>
      <div class="btn-row" style="justify-content:center">
        <button id="feed-give" class="btn primary">🍙 喂食（-1 食物 +10 心情）</button>
        <button id="feed-checkin" class="btn">📚 上课打卡</button>
      </div>`;
    const dlg = openDialog(`${st.pet.name} 的养成面板`, body);
    const moodEl = body.querySelector('#feed-mood');
    const affEl = body.querySelector('#feed-aff');
    const foodEl = body.querySelector('#feed-food');

    function renderStats() {
      const s = getState();
      moodEl.textContent = s.pet.mood;
      affEl.textContent = s.pet.affection;
      foodEl.textContent = s.pet.food;
    }
    renderStats();

    body.querySelector('#feed-give').addEventListener('click', () => {
      const s = getState();
      if (s.pet.food <= 0) { toast('没有食物啦，快去上课打卡！'); return; }
      s.pet.food -= 1;
      s.pet.mood = Math.min(100, s.pet.mood + 10);
      s.pet.affection = Math.min(100, s.pet.affection + 2);
      save();
      renderStats();
      toast(`${s.pet.name} 开心地吃掉了食物！`);
    });

    body.querySelector('#feed-checkin').addEventListener('click', () => {
      const s = getState();
      const week = currentWeekNumber(s.semester.startDate) || 1;
      const { current } = currentAndNext(coursesForWeek(s.courses, week), new Date());
      if (!current) { toast('现在没有在上课哦，打卡失败'); return; }
      s.pet.food += 1;
      s.pet.mood = Math.min(100, s.pet.mood + 10);
      s.pet.affection = Math.min(100, s.pet.affection + 5);
      save();
      renderStats();
      toast('打卡成功！获得 1 个食物 🍙');
    });
  });
}
```

- [ ] **Step 2: 修改 main.js 接入养成与心情衰减**

在 `prototype/js/main.js` import 区追加：

```js
import { initFeed } from './ui/feed.js';
```

在文件末尾追加：

```js
initFeed({ getState: () => state, save: () => store.save(state) });

// 心情随时间缓慢衰减（1/小时，下限 0）
setInterval(() => {
  state.pet.mood = Math.max(0, state.pet.mood - 1);
  store.save(state);
}, 3600000);
```

- [ ] **Step 3: 手动验证**

打开 http://localhost:8000 ，检查：
- [ ] 「🍙 养成」打开面板：心情/好感度/食物显示初始值（70/0/5）
- [ ] 喂食：食物 5→4、心情 70→80、好感度 0→2
- [ ] 没课时点打卡 → toast「现在没有在上课哦」；把某节课时间改成当前时间后打卡成功 +1 食物（改完记得改回）

- [ ] **Step 4: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/ui/feed.js prototype/js/main.js && git commit -m "feat: 养成面板（喂食/打卡/心情衰减）"
```

---

## Task 11: 设置面板（学期开始日/动画速度/角色/模拟开关/深色模式）

**Files:**
- Create: `prototype/js/ui/settings.js`
- Modify: `prototype/js/main.js`（接入设置 + 启动时应用深色模式）

- [ ] **Step 1: 实现 settings.js**

`prototype/js/ui/settings.js`：

```js
// 设置面板：学期开始日/动画速度/角色/模拟开关/深色模式/宠物名/清空数据
import { openDialog, toast } from './dialogs.js';

export function initSettings({ getState, save, onChanged }) {
  document.getElementById('btn-settings').addEventListener('click', () => {
    const s = getState();
    const body = document.createElement('div');
    body.className = 'dialog-body';
    body.innerHTML = `
      <div class="form-row"><label for="set-name">宠物名字</label><input id="set-name" value="${s.pet.name}"></div>
      <div class="form-row"><label for="set-start">学期开始日期（当天=第1周·单周）</label>
        <input id="set-start" type="date" value="${s.semester.startDate}"></div>
      <div class="form-row"><label for="set-speed">动画速度</label>
        <select id="set-speed">
          <option value="slow" ${s.settings.animSpeed === 'slow' ? 'selected' : ''}>慢</option>
          <option value="mid" ${s.settings.animSpeed === 'mid' ? 'selected' : ''}>中</option>
          <option value="fast" ${s.settings.animSpeed === 'fast' ? 'selected' : ''}>快</option>
        </select></div>
      <div class="form-row"><label for="set-char">宠物形象</label>
        <select id="set-char">
          ${[1, 2, 3].map((n) => `<option value="char${n}" ${s.settings.charId === `char${n}` ? 'selected' : ''}>角色 ${n}</option>`).join('')}
        </select></div>
      <div class="form-row"><label>系统状态模拟（原型期替代真实电量/音乐）</label>
        <label style="display:flex;align-items:center;gap:8px;font-size:14px;margin:6px 0"><input type="checkbox" id="set-sim-low" ${s.settings.simLowBattery ? 'checked' : ''}> 模拟电量低</label>
        <label style="display:flex;align-items:center;gap:8px;font-size:14px;margin:6px 0"><input type="checkbox" id="set-sim-charge" ${s.settings.simCharging ? 'checked' : ''}> 模拟充电中</label>
        <label style="display:flex;align-items:center;gap:8px;font-size:14px;margin:6px 0"><input type="checkbox" id="set-sim-music" ${s.settings.simMusic ? 'checked' : ''}> 模拟播放音乐</label>
      </div>
      <div class="form-row">
        <label style="display:flex;align-items:center;gap:8px;font-size:14px"><input type="checkbox" id="set-dark" ${s.settings.darkMode ? 'checked' : ''}> 深色模式</label>
      </div>
      <div class="btn-row">
        <button id="set-reset" class="btn" style="color:var(--danger)">清空全部数据</button>
        <button id="set-save" class="btn primary">保存</button>
      </div>`;
    const dlg = openDialog('设置', body);

    // 深色模式即时预览（保存前就能看效果）
    body.querySelector('#set-dark').addEventListener('change', (e) => {
      document.documentElement.dataset.theme = e.target.checked ? 'dark' : 'light';
    });

    body.querySelector('#set-save').addEventListener('click', () => {
      const st = getState();
      st.pet.name = body.querySelector('#set-name').value.trim() || '小火人';
      st.semester.startDate = body.querySelector('#set-start').value;
      st.settings.animSpeed = body.querySelector('#set-speed').value;
      st.settings.charId = body.querySelector('#set-char').value;
      st.settings.simLowBattery = body.querySelector('#set-sim-low').checked;
      st.settings.simCharging = body.querySelector('#set-sim-charge').checked;
      st.settings.simMusic = body.querySelector('#set-sim-music').checked;
      st.settings.darkMode = body.querySelector('#set-dark').checked;
      document.documentElement.dataset.theme = st.settings.darkMode ? 'dark' : 'light';
      save();
      dlg.close();
      toast('设置已保存');
      onChanged();
    });

    body.querySelector('#set-reset').addEventListener('click', () => {
      if (!confirm('确定清空全部数据（课表/养成进度/设置）？')) return;
      const st = getState();
      st.courses = [];
      st.pet.mood = 70; st.pet.affection = 0; st.pet.food = 5;
      save();
      dlg.close();
      toast('已清空');
      onChanged();
    });
  });
}
```

- [ ] **Step 2: 修改 main.js 接入设置**

在 `prototype/js/main.js` import 区追加：

```js
import { initSettings } from './ui/settings.js';
```

在文件末尾追加：

```js
initSettings({
  getState: () => state,
  save: () => store.save(state),
  onChanged: () => {
    viewingWeek = currentWeekNumber(state.semester.startDate) || 1;
    render();
    refreshPet();
  },
});

// 启动时应用已保存的深色模式
document.documentElement.dataset.theme = state.settings.darkMode ? 'dark' : 'light';
```

- [ ] **Step 3: 手动验证**

打开 http://localhost:8000 ，检查：
- [ ] 设置里改动画速度为「快」→ 保存 → 宠物帧切换明显变快
- [ ] 切换角色 2/3 → 宠物形象立即换成对应的抠图角色
- [ ] 勾「模拟电量低」→ 保存 → 宠物 30 秒内切到虚弱动作 + 气泡提醒充电；勾「模拟充电中」→ 充电动作；勾「模拟播放音乐」→ 听音乐动作（优先级：充电>低电量>音乐）
- [ ] 深色模式勾选 → 全页变暗，刷新后保持
- [ ] 学期开始日期改到 7 天前 → 保存 → 标题变「第 2 周 · 双周」，课表内容切换
- [ ] 清空全部数据 → 网格变空（空状态引导在 Task 13 补）

- [ ] **Step 4: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/ui/settings.js prototype/js/main.js && git commit -m "feat: 设置面板（学期/速度/角色/模拟开关/深色模式）"
```

---

## Task 12: 课间小游戏（接零食）

**Files:**
- Create: `prototype/js/ui/game.js`
- Modify: `prototype/js/main.js`（接入游戏）

- [ ] **Step 1: 实现 game.js**

`prototype/js/ui/game.js`：

```js
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
```

- [ ] **Step 2: 修改 main.js 接入游戏**

在 `prototype/js/main.js` import 区追加：

```js
import { initGame } from './ui/game.js';
```

在文件末尾追加：

```js
initGame({ getState: () => state, save: () => store.save(state) });
```

- [ ] **Step 3: 手动验证**

打开 http://localhost:8000 ，检查：
- [ ] 「🎮 小游戏」打开：零食下落，←→ 键和鼠标/手指拖动都能移动篮子
- [ ] 接住零食 +10 分；60 秒结束显示得分并兑换食物；养成面板里食物数增加
- [ ] 关闭弹层后键盘事件不再响应

- [ ] **Step 4: Commit**

```bash
cd /d/AI/CoursePet && git add prototype/js/ui/game.js prototype/js/main.js && git commit -m "feat: 接零食小游戏（得分换食物）"
```

---

## Task 13: 打磨（空状态/暗色收尾）+ 全流程手测 + 最终提交

**Files:**
- Modify: `prototype/css/style.css`（空状态样式）
- Modify: `prototype/js/ui/week-view.js`（空状态引导）
- Modify: `prototype/js/main.js`（用下方完整最终版替换，消除历次拼接的重复/遗漏）

- [ ] **Step 1: 空状态样式**

在 `prototype/css/style.css` 末尾追加：

```css
/* 空状态 */
.week-empty { grid-column: 1 / -1; text-align: center; padding: 48px 16px; color: var(--fg-dim); font-size: 15px; line-height: 2; }
.week-empty .big { font-size: 40px; }
```

- [ ] **Step 2: week-view.js 空状态引导**

在 `renderWeek` 函数开头（`gridEl.innerHTML = '';` 之后）插入：

```js
  if (!courses.length) {
    gridEl.innerHTML = `<div class="week-empty"><div class="big">📚</div>还没有课表<br>点右上角「＋ 导入课表」导入你的课表，<br>或去设置里清空数据恢复演示课表</div>`;
    return;
  }
```

- [ ] **Step 3: 用最终版替换 main.js**

`prototype/js/main.js` 完整最终版（覆盖写入）：

```js
// 装配入口：store + 状态机 + 周视图 + 宠物 + 导入/养成/设置/游戏
import { createStore } from './store.js';
import { currentWeekNumber, weekParityOf, formatDate } from './week.js';
import { coursesForWeek } from './schedule.js';
import { decideAction, bubbleFor } from './pet-state.js';
import { demoCourses } from './demo-data.js';
import { renderWeek, updateCountdown } from './ui/week-view.js';
import { initPet } from './ui/pet.js';
import { initImport } from './ui/import.js';
import { initFeed } from './ui/feed.js';
import { initSettings } from './ui/settings.js';
import { initGame } from './ui/game.js';

const store = createStore(localStorage);
let state = store.load();

// 首次使用：学期开始日设为今天 + 演示课表
if (!state.semester.startDate) {
  state.semester.startDate = formatDate(new Date());
  state.courses = demoCourses();
  store.save(state);
}

const weekTitle = document.getElementById('week-title');
const weekGrid = document.getElementById('week-grid');
const countdownBar = document.getElementById('countdown-bar');
const btnPrev = document.getElementById('btn-prev-week');
const btnNext = document.getElementById('btn-next-week');
const btnThis = document.getElementById('btn-this-week');

let viewingWeek = currentWeekNumber(state.semester.startDate) || 1;

function render() {
  const weekNumber = currentWeekNumber(state.semester.startDate);
  const parity = weekParityOf(viewingWeek);
  const prefix = viewingWeek === weekNumber ? '' : '（查看中）';
  weekTitle.textContent = `第 ${viewingWeek} 周 · ${parity === 'single' ? '单周' : '双周'}${prefix}`;
  const now = new Date();
  const displayNow = viewingWeek === weekNumber
    ? now
    : new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59); // 查看非本周时不高亮
  renderWeek(weekGrid, coursesForWeek(state.courses, viewingWeek), displayNow);
  updateCountdown(countdownBar, coursesForWeek(state.courses, weekNumber), now);
}

btnPrev.addEventListener('click', () => { viewingWeek = Math.max(1, viewingWeek - 1); render(); });
btnNext.addEventListener('click', () => { viewingWeek += 1; render(); });
btnThis.addEventListener('click', () => { viewingWeek = currentWeekNumber(state.semester.startDate) || 1; render(); });

// 倒计时每秒刷新
setInterval(() => {
  updateCountdown(countdownBar, coursesForWeek(state.courses, currentWeekNumber(state.semester.startDate) || 1), new Date());
}, 1000);

// 宠物
const petImg = document.getElementById('pet-img');
const petBubble = document.getElementById('pet-bubble');
let lastClickAt = null;
const pet = initPet(petImg, petBubble, {
  getCharId: () => state.settings.charId,
  getSpeed: () => state.settings.animSpeed,
  onClick: () => { lastClickAt = new Date(); refreshPet(); },
});

function refreshPet() {
  const ctx = {
    now: new Date(),
    courses: coursesForWeek(state.courses, currentWeekNumber(state.semester.startDate) || 1),
    charging: state.settings.simCharging,
    lowBattery: state.settings.simLowBattery,
    music: state.settings.simMusic,
    lastClickAt,
  };
  const r = decideAction(ctx);
  if (r.action !== pet.getAction()) pet.play(r.action);
  if (r.bubble) pet.showBubble(r.bubble);
  else if (Math.random() < 0.3) pet.showBubble(bubbleFor(state.pet.mood));
}
setInterval(refreshPet, 30000);

// 导入 / 养成 / 设置 / 游戏
initImport({
  onImport: (courses) => {
    state.courses = state.courses.concat(courses);
    store.save(state);
    render();
    refreshPet();
  },
});

initFeed({ getState: () => state, save: () => store.save(state) });

initSettings({
  getState: () => state,
  save: () => store.save(state),
  onChanged: () => {
    viewingWeek = currentWeekNumber(state.semester.startDate) || 1;
    render();
    refreshPet();
  },
});

initGame({ getState: () => state, save: () => store.save(state) });

// 深色模式 + 心情衰减（1/小时）
document.documentElement.dataset.theme = state.settings.darkMode ? 'dark' : 'light';
setInterval(() => {
  state.pet.mood = Math.max(0, state.pet.mood - 1);
  store.save(state);
}, 3600000);

render();
refreshPet();
```

- [ ] **Step 4: 回归测试**

Run: `cd /d/AI/CoursePet/prototype && node tests/run.mjs`
Expected: `✔ 全部测试通过`

- [ ] **Step 5: 全流程手测清单（逐项确认）**

打开 http://localhost:8000 ，按序走一遍：

- [ ] ① 首屏：周课表 7 列、演示课表 7 节课、今天列高亮、标题「第 1 周 · 单周」
- [ ] ② 倒计时条每秒跳动；上周/下周切换内容正确（第 2 周出现体育/Python，第 1 周出现英语/数据结构）
- [ ] ③ 宠物：待机呼吸动画；点击播放开心/兴奋后回待机；气泡 4 秒消失
- [ ] ④ 导入 `sample_files/课表示例.xlsx`：映射自动猜中 → 预览 7 条 → 导入成功 toast；再导一次选「单周」→ 追加且覆盖单双周
- [ ] ⑤ 养成：喂食扣食物加心情；上课时打卡 +1 食物；非上课时打卡被拒
- [ ] ⑥ 设置：动画速度三档生效；角色 1/2/3 切换生效；三个模拟开关逐一验证宠物动作（充电→charge、低电量→weak+气泡、音乐→listen）；深色模式即时切换且刷新保持；学期开始日期改 7 天前 → 第 2 周双周
- [ ] ⑦ 小游戏：键盘+拖动均可操作，结束兑换食物到养成面板
- [ ] ⑧ 清空数据 → 空状态引导文案出现
- [ ] ⑨ 窗口缩到手机宽度（<700px）：单列布局、宠物不遮挡内容、按钮可点
- [ ] ⑩ 刷新页面：所有数据保持（localStorage）

- [ ] **Step 6: Commit**

```bash
cd /d/AI/CoursePet && git add -A && git commit -m "feat: 原型打磨（空状态/深色收尾/最终装配）"
```

---

## Self-Review（计划自检结果）

**规格覆盖核对：**
- 课表核心（导入/映射/预览/单双周/周视图/高亮/倒计时/深色）→ Task 2/3/7/9/11 ✓
- 宠物基础（10 套状态动画/点击互动/气泡/状态机）→ Task 4/8 ✓
- 养成（喂食/心情/好感度/打卡得食物/心情衰减）→ Task 10 ✓
- 小游戏 → Task 12 ✓
- 设置（学期开始日/单双周切换/动画速度/宠物名/模拟开关）→ Task 11 ✓
- 空状态/响应式/四态 → Task 13 + Task 1 CSS ✓
- 二期功能（装扮/成就/考试倒计时/天气/Siri）→ 明确不做，不出现 ✓

**类型/接口一致性核对：**
- `decideAction(ctx, rand)` 与 main.js 调用参数一致 ✓
- `currentAndNext` 返回 `{current, next:{...,startDate}}`，pet-state/main/week-view 使用一致 ✓
- `openDialog` 返回 `{overlay, box, close, setOnClose}`，game.js 用 `setOnClose`、其余用 `close` ✓
- `initFeed({getState, save})` / `initSettings({getState, save, onChanged})` / `initGame({getState, save})` / `initImport({onImport})` / `initPet(img, bubble, {getCharId,getSpeed,onClick})` 与 main.js 调用一致 ✓
- 宠物帧路径 `../pet_assets/{charId}/pet_{action}_{i}.png` 与 process_pet.py 输出命名一致 ✓
- Task 13 的最终 main.js 覆盖了 Task 7-12 的所有增量修改，无遗漏 ✓

**占位符扫描：** 无 TBD/TODO；所有步骤含完整代码或具体命令与预期输出 ✓

---

## Execution Handoff

计划完成，保存于 `docs/superpowers/plans/2026-09-07-coursepet-prototype.md`。两种执行方式：

1. **Subagent-Driven（推荐）**：每个任务派一个全新子代理执行，任务间由我审查，迭代快
2. **Inline Execution**：本会话内按 executing-plans 批量执行，检查点审查

选哪种？


