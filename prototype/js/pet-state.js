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
