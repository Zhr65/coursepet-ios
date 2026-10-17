// 用 Node mock DOM 复刻金智(jsxsd)课表页结构，验证 School.swift 内嵌的 xjitExtractor v2
// 运行：node tests/test_xjit_extractor.mjs
// 覆盖场景：①正常网格表 ②「第一大节 08:00-09:40」带时间行标签 ③一格多课（单双周并排）
//           ④全角括号周次 ⑤备注格 colspan ⑥节次区间 01-02节 ⑦iframe 递归 ⑧CAS 检测
import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const swiftSrc = readFileSync(join(here, '..', 'ios', 'CoursePet', 'Agent', 'School.swift'), 'utf8');

// ── 从 Swift 里抠出 xjitExtractor 的 JS 字面量 ──
const start = swiftSrc.indexOf('static let xjitExtractor = #"""');
const bodyStart = swiftSrc.indexOf('#"""', start) + 4;
const bodyEnd = swiftSrc.indexOf('"""#', bodyStart);
assert.ok(start >= 0 && bodyEnd > bodyStart, 'School.swift 里应能定位 xjitExtractor');
const extractorJS = swiftSrc.slice(bodyStart, bodyEnd);

// ── 极简 DOM mock（够抽取器用：firstChild/nextSibling/tagName/textContent/querySelectorAll）──
// 关键：nextSibling/firstChild 必须放在公共基类上——cellLines 的 walk 会沿 firstChild/nextSibling
// 链遍历，链上既有元素节点也有文本节点（nodeType 3）；只在元素类上定义 getter 会让
// 文本节点的 nextSibling 恒为 undefined，遍历在第一个文本节点后就断（表现为只解析出第一行）。
class MockNode {
  constructor() { this.parent = null; this.children = []; }
  get firstChild() { return this.children[0] || null; }
  get nextSibling() {
    if (!this.parent) return null;
    const i = this.parent.children.indexOf(this);
    return this.parent.children[i + 1] || null;
  }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  append(...kids) { for (const k of kids) { k.parent = this; this.children.push(k); } return this; }
  appendChild(k) { return this.append(k); }
}
class MockText extends MockNode {
  constructor(text) { super(); this.nodeType = 3; this._text = text; }
  get textContent() { return this._text; }
}
class MockEl extends MockNode {
  constructor(tag, attrs = {}) {
    super();
    this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attrs = attrs;
  }
  getAttribute(n) { return this.attrs[n] ?? null; }
  querySelectorAll(sel) {
    const tags = sel.split(',').map((s) => s.trim().toUpperCase());
    const out = [];
    const walk = (node) => { for (const c of node.children) { if (tags.includes(c.tagName)) out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  getElementById(id) {
    // 递归：表单可能嵌在容器里（真实 DOM 也是全文档查找）
    if (this.attrs.id === id) return this;
    for (const c of this.children) {
      const hit = c.getElementById ? c.getElementById(id) : null;
      if (hit) return hit;
    }
    return null;
  }
  get options() { return []; }
}
function docOf(body) {
  const doc = new MockEl('html');
  doc.body = body;
  doc.appendChild(body);
  doc.querySelectorAll = (sel) => body.querySelectorAll(sel);
  doc.getElementById = (id) => body.getElementById(id);
  return doc;
}
function T(parent, text) { parent.append(new MockText(text)); }
function el(tag, attrs = {}) { return new MockEl(tag, attrs); }

// ── 复刻截图页面：表头「空+星期一..星期日」，数据行首列「第N大节 08:00-09:40」──
// 一格多课：周三第3大节格子并排「信号与系统（单周）/ 数据结构（双周）」+ 全角括号周次
function buildSchedulePage() {
  const body = el('body');
  const table = el('table');
  const head = el('tr');
  head.append(el('th'), ...['一', '二', '三', '四', '五', '六', '日'].map((d) => {
    const th = el('th'); T(th, '星期' + d); return th;
  }));
  table.append(head);
  // 第1大节（带时间行标签——v1 就是被这种行整列跳过）
  const r1 = el('tr');
  const c1 = el('td'); T(c1, '第一大节 08:00-09:40'); r1.append(c1);
  for (let i = 0; i < 7; i++) r1.append(el('td'));
  // 周一第1大节：高等数学 1-16周 教1-201
  const mon = el('td');
  T(mon, '高等数学'); mon.append(el('br'));
  T(mon, '张老师'); mon.append(el('br'));
  T(mon, '1-16周(01-02节)'); mon.append(el('br'));
  T(mon, '上课地点【教1-201】');
  r1.children[1] = mon;
  table.append(r1);
  // 第3大节：周三格一格两课（全角括号 + 单双周并排）
  const r3 = el('tr');
  const c3 = el('td'); T(c3, '第三大节 14:00-15:40'); r3.append(c3);
  for (let i = 0; i < 7; i++) r3.append(el('td'));
  const wed = el('td');
  T(wed, '信号与系统'); wed.append(el('br'));
  T(wed, '王老师'); wed.append(el('br'));
  T(wed, '1-16周（05-06节）'.replace('（', '(').replace('）', ')')); wed.append(el('br'));
  T(wed, '上课地点【教2-508】'); wed.append(el('br'));
  T(wed, '数据结构'); wed.append(el('br'));
  T(wed, '陈老师'); wed.append(el('br'));
  T(wed, '2,4,6,8,10,12,14,16周(05-06节)'); wed.append(el('br'));
  T(wed, '上课地点【实验楼B204】');
  r3.children[3] = wed;
  table.append(r3);
  // 附表：无课表课程（无星期一+星期日表头，应被跳过）
  const table2 = el('table');
  const tr2 = el('tr');
  const th2 = el('th'); T(th2, '无课表课程');
  const td2 = el('td'); T(td2, '马克思主义原理');
  tr2.append(th2, td2);
  table2.append(tr2);
  body.append(table, table2);
  return body;
}

// ── 执行抽取器 ──
// 用 new Function 把 document 作为参数注入（extractorJS 是自执行的 IIFE，返回 JSON 字符串）
function run(extractor, doc) {
  return new Function('document', `return (${extractor});`)(doc);
}

// 场景1：正常课表页
let res = JSON.parse(run(extractorJS, docOf(buildSchedulePage())));
assert.equal(res.diag.tables, 2, '识别出 2 个 table');
assert.equal(res.diag.header, true, '找到网格表头');
assert.equal(res.diag.sections, 2, '识别出 2 个节次行');
assert.equal(res.diag.cas, false, '非 CAS 页');
assert.ok(res.courses.length >= 3, '至少抽出 3 门课（高数+信号+数据结构），实际 ' + res.courses.length);

const gao = res.courses.find((c) => c.name === '高等数学');
assert.ok(gao, '抽出高等数学');
assert.equal(gao.day, 1, '高等数学在周一');
assert.equal(gao.startWeek, 1); assert.equal(gao.endWeek, 16);
assert.equal(gao.parity, 'both', '1-16周 → both');
assert.equal(gao.teacher, '张老师', '教师正确');
assert.equal(gao.location, '上课地点【教1-201】', '地点行完整收下');
assert.equal(gao.startPeriod, 1); assert.equal(gao.endPeriod, 2, '01-02节 → 节次 1-2');

const xinhao = res.courses.find((c) => c.name === '信号与系统');
assert.ok(xinhao, '一格多课第一门：信号与系统');
assert.equal(xinhao.day, 3, '信号与系统在周三');
assert.equal(xinhao.teacher, '王老师', '状态机正确切块（没把教师当后课课名）');
assert.equal(xinhao.location, '上课地点【教2-508】', '地点没丢进残余段');
assert.equal(xinhao.parity, 'both', '1-16周全奇偶混合 → both');
assert.equal(xinhao.startPeriod, 5); assert.equal(xinhao.endPeriod, 6, '（05-06节）区间生效');

const shuju = res.courses.find((c) => c.name === '数据结构');
assert.ok(shuju, '一格多课第二门：数据结构');
assert.equal(shuju.day, 3);
assert.equal(shuju.teacher, '陈老师', '第二门课教师正确（没串到第一门的地点）');
assert.equal(shuju.location, '上课地点【实验楼B204】', '第二门课地点正确');
assert.equal(shuju.parity, 'double', '2,4,6,8,10,12,14,16周 → double');
assert.equal(shuju.startWeek, 2); assert.equal(shuju.endWeek, 16, '逗号周次展开取 min/max');
assert.equal(shuju.startPeriod, 5); assert.equal(shuju.endPeriod, 6);

// 附表「无课表课程」不能被当课表抽进来
assert.ok(!res.courses.some((c) => c.name === '无课表课程'), '附表不参与抽取');

// 场景2：CAS 登录页（未登录）
const casBody = el('body');
casBody.attrs.id = 'cas-login';
const fm = el('form'); fm.attrs.id = 'fm1';
const pwd = el('input'); pwd.attrs.type = 'password';
const cap = el('div'); T(cap, '验证码');
fm.append(pwd, cap);
casBody.append(fm);
const casRes = JSON.parse(run(extractorJS, docOf(casBody)));
assert.equal(casRes.diag.cas, true, 'CAS 页检测命中');
assert.equal(casRes.courses.length, 0, 'CAS 页无课程');
assert.equal(casRes.diag.header, false);

// 场景3：iframe 里的课表（顶层无网格表）
const frameBody = el('body');
const iframe = el('iframe');
iframe.contentDocument = docOf(buildSchedulePage());
frameBody.append(iframe);
const frRes = JSON.parse(run(extractorJS, docOf(frameBody)));
assert.equal(frRes.diag.header, true, 'iframe 递归找到课表');
assert.ok(frRes.courses.length >= 3, 'iframe 里的课程被抽出');

// 场景4：备注格（colspan）不重复解析
const noteBody = buildSchedulePage();
const noteTable = noteBody.children[0];
const noteRow = el('tr');
const noteCell = el('td', { colspan: 7 }); T(noteCell, '备注:本课表仅供参考');
noteRow.append(noteCell);
noteTable.append(noteRow);
const noteRes = JSON.parse(run(extractorJS, docOf(noteBody)));
assert.ok(!noteRes.courses.some((c) => c.name.includes('备注')), '备注格不当课程');
assert.ok(!noteRes.courses.some((c) => c.name.includes('本课表')), '备注格不产生残余课名');

console.log('✔ xjitExtractor v2 全部断言通过（' + res.courses.length + ' 门课 / CAS / iframe / 备注格）');
