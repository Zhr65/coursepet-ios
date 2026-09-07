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
