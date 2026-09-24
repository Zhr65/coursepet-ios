# CoursePet iOS 项目

基于 Web 原型（`prototype/`）的 iOS 原生实现，支持 WidgetKit 桌面小组件和 Live Activity 灵动岛。

## 目录结构

```
ios/
├── Shared/                        # 共享模块（数据模型 + 逻辑，BUILD_LIBRARY_FOR_DISTRIBUTION）
│   ├── Models.swift               # Course/Semester/Pet/Settings 数据模型
│   ├── WeekMath.swift             # 周数计算（对应 prototype/js/week.js）
│   ├── ScheduleHelpers.swift      # 课程时间逻辑（对应 prototype/js/schedule.js）
│   ├── PetStateMachine.swift      # 宠物状态机（对应 prototype/js/pet-state.js）
│   ├── DataManager.swift          # App Group JSON 持久化
│   ├── ExcelParser.swift          # .xlsx 解析器（SSZipArchive + XMLParser）
│   ├── PetUIView.swift            # PetAnimationView + PetBubble（public，供所有扩展使用）
│   └── WidgetExtensions.swift     # Widget 通用扩展
│
├── CoursePet/                     # 主 App（SwiftUI）
│   ├── CoursePetApp.swift         # @main 入口
│   ├── Views/
│   │   ├── ScheduleView.swift     # 课表主视图（含倒计时）
│   │   ├── FeedView.swift         # 养成面板（心情/喂食/打卡）
│   │   ├── GameView.swift         # 接零食小游戏
│   │   ├── SettingsView.swift     # 设置面板
│   │   └── PetView.swift          # 类型别名（import Shared）
│   ├── Import/
│   │   └── ExcelImportView.swift  # Excel 导入界面（自动列检测）
│   ├── Assets.xcassets/           # App 图标、强调色
│   ├── Info.plist
│   └── CoursePet.entitlements     # App Group 权限
│
├── CoursePetWidgets/              # WidgetKit 扩展
│   ├── CoursePetWidgets.swift     # @main WidgetBundle
│   ├── Models.swift               # TimelineEntry + TimelineProvider
│   ├── CoursePetSmallWidget.swift # 小尺寸（下一节课 + 宠物帧）
│   ├── CoursePetMediumWidget.swift # 中尺寸（今日课程列表）
│   ├── CoursePetLargeWidget.swift  # 大尺寸（本周课表格子）
│   ├── Assets.xcassets/
│   ├── Info.plist
│   └── CoursePetWidgets.entitlements
│
├── CoursePetLiveActivity/         # ActivityKit 扩展（灵动岛）
│   ├── CoursePetLiveActivity.swift # @main
│   ├── CourseActivityAttributes.swift # 活动属性定义
│   ├── CoursePetLiveActivityView.swift # 灵动岛视图
│   ├── LiveActivityManager.swift  # 自动启动/更新/结束
│   ├── LiveActivityBundle.swift
│   ├── Info.plist                 # NSSupportsLiveActivities = YES
│   └── CoursePetLiveActivity.entitlements
│
├── project.yml                    # XcodeGen 工程定义
├── build.sh                       # Mac/Linux 构建脚本
├── build.bat                      # Windows 构建脚本
├── setup_pet_assets.bat           # 部署宠物帧到模拟器
└── README.md                      # 本文档
```

## 快速开始

### 前提条件

1. **Mac** 上安装 Xcode 15+ 和 iOS 16.1+ SDK
2. 安装 XcodeGen（可选，用于自动生成工程）：
   ```bash
   brew install xcodegen
   ```

### 生成 Xcode 工程

```bash
cd ios
./build.sh generate
# 或 Windows:
.\build.bat generate
```

### 在 Xcode 中打开

```bash
open CoursePet.xcodeproj
```

### 关键配置（必须在 Xcode 中完成）

1. **Bundle Identifier**：改为你的唯一标识（如 `com.yourname.coursepet`）
2. **Development Team**：填入你的 Apple Developer Team ID（或免费账号）
3. **App Groups Capability**：
   - 主 App → Signing & Capabilities → + Capability → App Groups
   - 勾选 `group.com.coursepet.app`
   - Widget 和 Live Activity 扩展同样添加此 Capability
4. **Live Activities 权限**：
   - Live Activity 扩展 → Signing & Capabilities → 确认 `NSSupportsLiveActivities = YES`（已在 Info.plist 中设置）

### 部署宠物帧动画（测试用）

```bash
# Windows
.\setup_pet_assets.bat

# Mac/Linux
# 将 pet_assets/ 复制到模拟器容器：
cp -r ../../pet_assets/char* ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Library/Application\ Support/group.com.coursepet.app/Documents/PetAnimations/
```

## 功能对照（Web 原型 → iOS）

| 功能 | Web 原型 | iOS 实现 |
|------|----------|----------|
| 课表模型 | `js/schedule.js` | `Shared/Models.swift` |
| 周数计算 | `js/week.js` | `Shared/WeekMath.swift` |
| 当前/下节 | `currentAndNext()` | `ScheduleHelpers.currentAndNext()` |
| 宠物状态机 | `js/pet-state.js` | `Shared/PetStateMachine.swift` |
| 存储 | `localStorage` | App Group JSON + UserDefaults |
| 周视图 | `js/ui/week-view.js` | `Views/ScheduleView.swift` |
| 养成面板 | `js/ui/feed.js` | `Views/FeedView.swift` |
| 小游戏 | `js/ui/game.js` | `Views/GameView.swift` |
| 设置 | `js/ui/settings.js` | `Views/SettingsView.swift` |
| 桌面小组件 | — | `CoursePetWidgets/`（三尺寸）|
| 灵动岛 | — | `CoursePetLiveActivity/` |
| Excel 导入 | SheetJS (CDN) | SSZipArchive + 原生 XML 解析 |

## 数据共享架构

```
主 App ──写入──► group.com.coursepet.app
                   ├─ Documents/courses.json    （课程数据）
                   └─ UserDefaults suite        （宠物状态/设置）
                         ▲
    Widget ──────────────┤ 读取
    Live Activity ───────┘
```

## 宠物帧动画

每个动作 8 帧 PNG，存放在 App Group Documents 下的 `PetAnimations/{charId}/` 目录。

动作类型：
- `idle` — 待机（循环）
- `walk` — 走路（循环）
- `happy` — 开心（播一次）
- `excite` — 兴奋（播一次）
- `nervous` — 紧张（课前15分钟）
- `sleep` — 睡觉（循环）
- `listen` — 听音乐（循环）
- `charge` — 充电（循环）
- `weak` — 虚弱/低电量（循环）
- `rain` — 下雨（二期）

文件名规范：`pet_{action}_{frameIndex}.png`，如 `pet_idle_0.png`

## Excel 导入格式

第一行作为表头（自动检测），支持以下列名：

| 中文 | 英文 | 示例值 |
|------|------|--------|
| 课程名称 / 名称 / name | — | 高等数学 |
| 教师 / 老师 / teacher | — | 张老师 |
| 地点 / 教室 / location | — | 教3-201 |
| 星期几 / 周几 / day | 1-7 | 3 |
| 开始时间 / start | — | 09:00 |
| 结束时间 / end | — | 10:30 |
| 起始周 / 开始周 | — | 1 |
| 结束周 / 终止周 | — | 18 |

支持两种导入模式：
- **单周**：导入一个 `.xlsx` 文件
- **单周+双周**：导入两个文件（分别代表奇数周和偶数周）

## 编译安装

### 本地编译（有 Mac）

1. 在 Xcode 中选择你的 iPhone 设备
2. 点击 Run（⌘R）
3. 首次需要在设备上信任开发者证书

### 无 Mac？使用 Codemagic 云端构建（推荐）

完整指南：[docs/codemagic-guide.md](../docs/codemagic-guide.md)

快速流程：
1. 将项目推送到 GitHub
2. 在 [Codemagic](https://codemagic.io) 关联仓库
3. 配置 Apple ID（Settings → Security → Key Chains）
4. 触发构建，下载 IPA
5. 用 AltStore 安装到 iPhone（免费账号每周重签一次）

> Codemagic 免费版每月 500 分钟构建时长，足够个人使用。
