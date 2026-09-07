# CoursePet 课程表宠物 — 设计文档

- 日期：2026-09-07
- 状态：✅ 用户已确认（2026-09-07 确认，项目移至 D:\AI\CoursePet）
- 需求来源：D:\桌面\设计.txt（课程表宠物 iOS App 需求文档）

---

## 1. 项目概述

iOS 课程表 App + 虚拟宠物。用户（学生）自用。核心价值：不用打开 App 也能看课表（桌面小组件 / 灵动岛），宠物按课程状态与系统状态做出反应，提供陪伴感。

## 2. 关键决策记录（为什么这么定）

| 决策 | 结论 | 原因 |
|---|---|---|
| 开发顺序 | **网页交互原型先行 → 原生 iOS 代码后写** | 无 Mac：改一次代码等云端编译 10-20 分钟，原型秒级迭代；原型定稿后照写 Swift，逻辑一一对应 |
| 编译 | Codemagic 免费层（500 分钟/月 macOS 构建） | 无 Mac 的唯一免费云端编译方案 |
| 安装到 iPhone | SideStore（备选 AltStore），免费 Apple ID 签名，**每周续签** | iOS 17.7 不支持 TrollStore（仅到 17.0）；不买 $99 开发者账号的最优解 |
| 宠物素材 | **用户提供小火人风格截图 → 自动加工管线**（抠图 + 10 套动画帧），不用 AI 手绘 | 用户原图是 3D 渲染，直接使用 100% 还原想要的效果 |
| 宠物动画帧 | 2.5D 静态图 + 程序变形（呼吸/蹦跳/摇摆/抖动/变暗/发光） | 单张截图无法换表情/换姿势，身体语言靠变形实现；需要闭眼等表情时用户另供图 |
| 数据存储（原型） | localStorage | 零依赖、够用 |
| 数据存储（原生） | App Group 共享 JSON + UserDefaults | 设计文档建议的简化方案，弃 CoreData |
| 技术栈（原型） | 纯 HTML+CSS+JS 零构建 + SheetJS（CDN 单文件）解析 Excel | 最少依赖铁律；浏览器端 SheetJS 顺带支持 .xls |

### 设计.txt 中与 iOS 系统现实冲突的 4 点修正（重要）

| 原文要求 | 现实 | 修正方案 |
|---|---|---|
| 小组件每秒切帧动画 | WidgetKit 刷新被系统严格限流（实际几分钟级） | 静态帧，仅随课程节点切换状态图 |
| 灵动岛 0.2s/帧动画 | Live Activity 更新被限流 | 静态帧；倒计时用 SwiftUI `Text(timerInterval:)` **系统驱动**，不占更新额度，正常走秒 |
| 课前 15 分钟后台自动启动灵动岛 | 后台无法可靠启动 Live Activity | 本地通知提醒用户打开 App；App 打开/前台时自动启动；二期可加远程推送 |
| .xls 解析（原生） | Swift 无成熟 .xls 库 | 原生只支持 .xlsx（CoreXLSX）；原型阶段 SheetJS 两种都支持 |

## 3. 范围

### 第一版（本次实现）
- 课表核心：Excel 导入（单周/双周两个文件）、字段手动映射、预览确认、手动增删改、单双周自动/手动切换、周视图、当前课程高亮 + 下一节倒计时、深色模式
- 宠物基础：10 套状态动画、点击互动（随机动作+震动+气泡文字）、状态机驱动
- 养成系统：喂食、心情值、好感度、上课打卡得食物
- 课间小游戏：接零食（canvas，得分换食物）
- 设置：学期开始日期、单双周手动切换、动画速度（慢/中/快）、宠物名字、模拟开关（电量/音乐，原型期用）
- 原生专属（阶段 2）：小组件三尺寸、灵动岛、真实系统联动（电量/耳机/音乐）

### 二期（明确不做）
装扮+成就、考试倒计时、天气联动、自定义形象包（ZIP 导入）、Siri、小组件按钮（iOS 17 App Intents）、日历订阅提醒、远程推送。

## 4. 数据模型

JS 对象（阶段 2 对应 Swift struct，字段一致）：

```js
Course   { id, name, teacher, location, dayOfWeek(1-7), startTime("HH:mm"), endTime,
           startWeek, endWeek, weekParity: 'single'|'double'|'both', color }
Semester { startDate: 'YYYY-MM-DD' }
Pet      { name, action, mood(0-100), affection(0-100), food, bubbleText }
Settings { remindEnabled, animSpeed: 'slow'|'mid'|'fast', darkMode, simLowBattery, simMusic }
```

- 周数计算：`floor((今天 - 学期开始日) / 7天) + 1`；周数为奇数 → 单周课表，偶数 → 双周课表
- `weekParity: 'both'` 的课每周都有；`'single'/'double'` 只在对应周显示
- 学期开始日必须 ≤ 今天（校验）

## 5. 原型结构（阶段 1，D:\AI\CoursePet\prototype\）

单页应用 + 弹层，移动优先响应式，CSS 变量驱动深色模式：

1. **周课表主视图**：周一~周日 7 列（手机竖排可滑），课程块显示名称/地点/时间，柔和色自动分配。顶部「第 X 周 · 单周/双周」+ 上周/本周/下周切换。当前课程高亮，顶部倒计时条（上课中剩余 / 距下节课）
2. **宠物区**：课表角落宠物，播放当前状态帧动画（待机类循环 0.5s/帧；触发类播一遍回待机；速度设置映射 0.7/0.5/0.3s/帧）。点击 → 随机开心/兴奋 + 震动（移动端 Vibration API）+ 气泡文字
3. **导入流程**（弹层）：选单周/双周文件 → SheetJS 解析 → 字段映射界面 → 预览 → 入库
4. **养成面板**：心情/好感度/食物数、喂食按钮、上课打卡按钮
5. **小游戏**：接零食 canvas 游戏（60 秒）
6. **设置**：上述 Settings 字段

交互规范：四态齐全（加载/空/错误/成功）、空课表引导导入、所有可点击元素 hover/focus/active、44px 最小触摸区、深色模式。

## 6. 宠物状态机（PetStateManager）

输入（当前时间 + 课程 + 系统状态 + 用户互动）→ 输出 action（映射 pet_assets 的 10 套帧）：

| 条件（按优先级从上到下） | action |
|---|---|
| 正在充电（原生真实 / 原型模拟开关） | charge |
| 电量 < 20%（原生真实 / 原型模拟开关） | weak + 气泡「要充电啦」 |
| 播放音乐（原生真实 / 原型模拟开关） | listen |
| 用户刚点击宠物（5 秒内） | happy / excite 随机 |
| 课前 15 分钟内 | nervous |
| 上课中（每 5 分钟 20% 概率） | sleep，否则 idle |
| 课间 10 分钟 | walk / excite 随机 |
| 无课 | idle |
| 下雨（二期，天气 API） | rain |

- **心情值的作用**（表情不可变，心情体现在气泡文案）：mood ≥ 80 用开心文案，≤ 30 用低落文案，其余中性文案；喂食 +10，按时打卡 +15，随时间缓慢 -1/小时（下限 0）

- 动画循环：待机类（idle/walk/listen/sleep/weak/rain/charge）循环播放；触发类（happy/excite/nervous）播一遍后回待机
- 原型限制（诚实说明）：浏览器拿不到真实电量/耳机/音乐状态 → 设置页模拟开关；原生阶段用 UIDevice/AVAudioSession/MPMusicPlayerController，状态机逻辑 JS→Swift 直接移植

## 7. 原生 iOS 规划（阶段 2，D:\AI\CoursePet\ios\）

- **工程**：XcodeGen `project.yml`，三 target：主 App / Widget Extension / Live Activity，部署目标 iOS 16.1+
- **数据**：App Group（group.com.coursepet）共享 JSON + UserDefaults；主 App 写、扩展读
- **小组件**：小 = 下一节课 + 宠物静态帧；中 = 今日列表 + 当前高亮 + 宠物；大 = 本周格子 + 宠物角落。TimelineProvider 在课程开始/结束节点刷新
- **灵动岛**：`CourseActivityAttributes`；本地通知课前 15 分钟提醒 → 用户打开 App 时自动启动；compact = 宠物小图 + 课程缩写，expanded = 完整信息 + `Text(timerInterval:)` 倒计时 + 宠物静态帧；课程状态变化时更新帧与文案
- **系统监听**：UIDevice.batteryState、AVAudioSession 耳机、MPMusicPlayerController 音乐（App 运行期间生效，写入 App Group 供扩展读取）
- **素材**：pet_assets 的 charN/pet_{action}_{i}.png 全部进 Asset Catalog；加新图 → 重跑管线 → 重新编译
- **Excel**：CoreXLSX（.xlsx）
- **编译安装链路**：GitHub 仓库 → Codemagic 云端编译 → 下载 ipa → SideStore 签名安装（每周续签）

## 8. 边界与错误处理

- Excel 解析失败/列缺失 → 字段映射界面兜底；只导了单周没导双周 → 提示「双周可先复用单周文件」
- 学期开始日在未来 → 校验提示
- 空课表 → 引导导入空状态，不白屏
- 跨午夜课程（如 22:00-00:30）→ 显示在开始日，倒计时按绝对时间计算
- 断网 → 原型纯本地，可离线

## 9. 测试策略

- 原型手测清单：导入 → 映射 → 预览 → 编辑 → 周切换 → 单双周校验 → 宠物互动 → 打卡/喂食 → 游戏 → 设置，手机/桌面两种宽度
- JS/Swift 对照用例（两边同逻辑，用同一组输入对照结果）：周数计算、单双周判定、状态机各分支、跨午夜课程
- 阶段 2 以「Codemagic 编译通过」为验证标准，真机功能逐项手测

## 10. 目录结构

```
D:\AI\CoursePet\
├── prototype\     # 阶段 1：网页交互原型（纯 HTML+CSS+JS）
├── ios\           # 阶段 2：原生 iOS 代码（XcodeGen 工程）
├── pet_source\    # 用户原始图（charN\ 每角色一个文件夹）
├── pet_assets\    # 加工后帧（charN\pet_{action}_{i}.png，256×256 透明 PNG）
├── tools\         # 加工/预览脚本（process_pet.py / make_preview_cutout.py / analyze.py / pet_gen.py）
└── docs\superpowers\specs\   # 本设计文档
```

### 宠物素材管线用法
1. 把新图放入 `pet_source\charN\`
2. 运行 `python tools/process_pet.py`（抠图容差 TOL、动画幅度都在脚本顶部可调）
3. 输出到 `pet_assets\charN\`：`pet_idle.png`（静态）+ 10 套动作 × 8 帧 `pet_{action}_{i}.png`
