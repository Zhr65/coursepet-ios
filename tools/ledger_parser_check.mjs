// 银行/支付短信解析器的回归测试
// （等价复刻 ios/CoursePet/Agent/SMS/BankPayParser.swift 的正则逻辑）
//
// 为什么会有这个文件：BankPayParser 全是正则，而正则极其「改一处崩一处」。
// 开发第一版就被坑过 ——「微信支付-美团外卖 25.50元」被解析成 ¥6666.00，
// 因为「微信支付」里的「支付」触发了锚点，锚点跨过「尾号」把卡号当成了消费额。
//
// 用法：node tools/ledger_parser_check.mjs
// 改完 BankPayParser 的正则后请重跑，全绿再提交。
//
// 注：NSRegularExpression 基于 ICU，与 JS RegExp 在本脚本用到的语法
//     （字符类、量词、捕获组、非贪婪）上语义一致，故可这样交叉验证。

const noiseAmountPatterns = [
  /余额[^，,。;；]{0,24}?元/g,
  /可用额度[^，,。;；]{0,24}?元/g,
  /额度[^，,。;；]{0,24}?元/g,
  /剩余[^，,。;；]{0,24}?元/g,
  /可用[^，,。;；]{0,24}?元/g,
  /积分[^，,。;；]{0,24}?分/g,
];
const yuanAmountPattern = /([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*元/g;
const symbolAmountPattern = /[¥￥]\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/g;

const expenseWords = ["消费","支出","扣款","付款","购买","已扣","代扣","转出","缴纳","缴费","支付"];
const incomeWords = ["入账","到账","收入","转入","退款","退回","返现","报销","工资","红包","存入","收到","收款"];

const merchantMap = [
  { words:["美团","饿了么","肯德基","麦当劳","星巴克","瑞幸","蜜雪","食堂","外卖","餐饮","饭店","餐厅","美食","烧烤","火锅","奶茶","咖啡","面馆","小吃"], cat:"餐饮" },
  { words:["滴滴","高德","地铁","公交","铁路","12306","加油","石油","石化","出租","打车","单车","哈啰","青桔","车费","停车","高速","机票","航空"], cat:"交通" },
  { words:["书店","当当","文具","打印","复印","学费","课程","网课","知网","图书馆","教育","培训","考试","报名","教材","学习"], cat:"学习" },
  { words:["超市","永辉","沃尔玛","便利店","盒马","买菜","淘宝","天猫","京东","拼多多","日用","百货","商场","药店","屈臣氏","名创优品","家电","数码"], cat:"日用" },
  { words:["电影","影院","游戏","腾讯视频","爱奇艺","优酷","哔哩哔哩","网易云","QQ音乐","Steam","网吧","KTV","娱乐","会员","演出","门票"], cat:"娱乐" },
];
const channelWords = ["支付宝","微信支付","财付通","云闪付","银联","花呗","京东支付","美团支付","抖音支付"];

function firstGroup(re, text) {
  const m = re.exec(text);
  if (!m || m.length < 2 || m[1] === undefined) return null;
  const v = m[1].trim();
  return v === "" ? null : v;
}
function strippingChannelSuffix(text) {
  return text.replace(/(微信|京东|美团|抖音|华为|小米|苹果|银联)支付/g, "$1");
}
function removingNoiseAmounts(text) {
  let out = text;
  for (const p of noiseAmountPatterns) out = out.replace(p, " ");
  return out;
}
function amountCandidates(text) {
  const found = [];
  for (const p of [yuanAmountPattern, symbolAmountPattern]) {
    for (const m of text.matchAll(p)) {
      const v = parseFloat(m[1].replace(/,/g, ""));
      if (!Number.isNaN(v)) found.push({ location: m.index, value: v });
    }
  }
  return found.sort((a, b) => a.location - b.location);
}
function extractTradeAmount(cleaned) {
  const cs = amountCandidates(cleaned);
  if (!cs.length) return null;
  for (const c of cs) {
    const prefix = cleaned.slice(Math.max(0, c.location - 16), c.location);
    if (expenseWords.some(w => prefix.includes(w))) return c.value;
  }
  return cs[0].value;
}
function isExpense(text) {
  if (incomeWords.some(w => text.includes(w))) return false;
  return expenseWords.some(w => text.includes(w));
}
function extractMerchant(text) {
  for (const g of merchantMap) { const hit = g.words.find(w => text.includes(w)); if (hit) return hit; }
  const explicit = firstGroup(/在([^，,。;；\s¥￥]{2,14}?)(?:消费|付款|购买|就餐|结账)/, text);
  if (explicit && channelWords.includes(explicit)) return null;
  return explicit;
}
function categoryFor(merchant) {
  if (!merchant) return "其他";
  for (const g of merchantMap) if (g.words.includes(merchant)) return g.cat;
  return "其他";
}
function buildNote(merchant, channel, tail) {
  const parts = [];
  if (merchant) parts.push(merchant);
  if (channel && channel !== merchant) parts.push(channel);
  if (tail) parts.push("尾号" + tail);
  return parts.join("·");
}
function parse(text) {
  const body = text.trim();
  if (!body) return null;
  const neutral = strippingChannelSuffix(body);
  const cleaned = strippingChannelSuffix(removingNoiseAmounts(body));
  const amount = extractTradeAmount(cleaned);
  if (amount == null || amount <= 0) return null;
  const merchant = extractMerchant(body);
  const channel = channelWords.find(w => body.includes(w)) || null;
  const tail = firstGroup(/尾号\s*([0-9]{4})/, body);
  return { amount, isExpense: isExpense(neutral), category: categoryFor(merchant), note: buildNote(merchant, channel, tail) };
}

// ── 样本（真实银行/支付短信格式）──────────────────────────────
// [短信, 期望金额, 期望isExpense(决定是否落账), 期望分类, 期望备注]
const cases = [
  ["【工商银行】您尾号1234的储蓄卡10月12日19:30消费人民币25.50元，余额1,234.56元。", 25.50, true, "其他", "尾号1234"],
  ["【建设银行】您尾号5678的信用卡10月12日在支付宝消费38.00元。", 38.00, true, "其他", "支付宝·尾号5678"],
  ["【招商银行】您账户10月12日入账人民币2000.00元（跨行转存），余额5000.00元。", 2000.00, false, "其他", ""],
  ["【招商银行】您尾号6666的信用卡10月12日在微信支付消费25.50元。", 25.50, true, "其他", "微信支付·尾号6666"],
  ["【蚂蚁花呗】您的花呗已扣款88.00元，请及时还款。", 88.00, true, "其他", "花呗"],
  ["您尾号8888账户10月12日19:30向张三转账500.00元，余额1,000.00元。", 500.00, false, "其他", "尾号8888"],
  ["【银联】您尾号1234的银行卡10月12日19:30消费(支付宝)人民币25.50元。", 25.50, true, "其他", "支付宝·尾号1234"],
  ["【工商银行】您尾号1234的储蓄卡10月12日19:30支出(消费)人民币128.00元，余额2,345.67元。", 128.00, true, "其他", "尾号1234"],
  ["【交通银行】您尾号9012的信用卡10月12日在滴滴出行消费23.80元，可用额度8,000.00元。", 23.80, true, "交通", "滴滴·尾号9012"],
  ["【中国银行】您尾号3456的储蓄卡10月12日在永辉超市消费156.30元，余额3,456.78元。", 156.30, true, "日用", "超市·尾号3456"],
  ["【建设银行】您尾号7788的储蓄卡10月12日网上支付29.90元，余额888.00元。", 29.90, true, "其他", "尾号7788"],
  ["【工商银行】您尾号1234的储蓄卡10月12日退款入账人民币50.00元，余额1,050.00元。", 50.00, false, "其他", "尾号1234"],
  ["【招商银行】您尾号1234的信用卡10月12日消费人民币1,234.56元。", 1234.56, true, "其他", "尾号1234"],
  ["【工商银行】您尾号1234的账户余额5,000.00元，10月12日消费25.50元。", 25.50, true, "其他", "尾号1234"],
  ["【某某银行】尊敬的客户，您的账户状态正常，如有疑问请联系客服。", null, null, null, null],
  // ── 回归样本：早期版本会把这笔记成 ¥6666.00（卡尾号被当金额）──
  ["【微信支付】您尾号6666的银行卡10月12日微信支付-美团外卖 25.50元。", 25.50, false, "餐饮", "美团·微信支付·尾号6666"],
  // ── 回归样本：先出现余额、后出现交易额 ──
  ["【建设银行】您尾号4321的储蓄卡余额12,000.00元，10月12日在滴滴打车消费18.60元。", 18.60, true, "交通", "滴滴·尾号4321"],
  // ── 回归样本：带 ¥ 符号、无「元」字 ──
  ["【支付宝】您10月12日在瑞幸咖啡支付 ¥32.00。", 32.00, true, "餐饮", "瑞幸·支付宝"],
];

let pass = 0, fail = 0;
console.log("     | 金额       | 落账 | 分类  | 备注");
console.log("-".repeat(84));
for (const [text, expAmt, expExp, expCat, expNote] of cases) {
  const r = parse(text);
  const gotAmt = r ? r.amount : null;
  const gotExp = r ? r.isExpense : null;
  const gotCat = r ? r.category : null;
  const gotNote = r ? r.note : null;
  const ok = (gotAmt === expAmt) && (gotExp === expExp) && (gotCat === expCat) && (gotNote === expNote);
  if (ok) pass++; else fail++;
  const shown = r ? `¥${r.amount.toFixed(2)}` : "（不解析）";
  console.log(`${ok ? "PASS" : "FAIL"} | ${shown.padEnd(9)} | ${String(gotExp).padEnd(4)} | ${String(gotCat).padEnd(5)} | ${gotNote === "" ? "（无）" : (gotNote ?? "-")}`);
  if (!ok) {
    console.log(`     ↳ 短信: ${text}`);
    console.log(`     ↳ 期望: ¥${expAmt} / 落账=${expExp} / ${expCat} / ${expNote === "" ? "（无）" : expNote}`);
    console.log(`     ↳ 实得: ¥${gotAmt} / 落账=${gotExp} / ${gotCat} / ${gotNote === "" ? "（无）" : gotNote}`);
  }
}
console.log("-".repeat(84));
console.log(`RESULT: ${pass} PASS / ${fail} FAIL  (共 ${cases.length} 条)`);
