// 零依赖测试入口：node tests/run.mjs（在仓库根目录执行）
// 覆盖两类：
//   1. Web 原型逻辑（prototype/tests 下的纯 JS 逻辑层，TDD 老测试）
//   2. iOS 内嵌 JS 抽取器（School.swift 的 xjitExtractor，用 mock DOM 验证）
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
let failed = 0;

function run(label, cwd, args) {
  // stdio: 'inherit' —— Windows 沙箱下管道捕获子进程输出会 EPERM，直接继承 stdout/stderr
  const r = spawnSync(process.execPath, args, { cwd, stdio: 'inherit' });
  if (r.status !== 0) {
    failed++;
    console.error(`✘ ${label} 失败（exit ${r.status}）`);
  }
}

console.log('── Web 原型逻辑测试 ──');
run('prototype', join(root, 'prototype'), ['tests/run.mjs']);

console.log('── iOS 内嵌 JS 抽取器测试 ──');
run('xjit-extractor', root, ['tests/test_xjit_extractor.mjs']);

if (failed) { console.error(`\n✘ ${failed} 组测试失败`); process.exit(1); }
console.log('\n✔ 全部测试通过');
