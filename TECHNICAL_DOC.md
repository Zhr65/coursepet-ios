# CoursePet 技术详解文档

> 本文档分 **通俗版** 和 **技术版** 两个视角，帮你彻底搞懂这个项目。
> - 🗣️ **通俗版**：用大白话讲"是什么、能干嘛"
> - 🔧 **技术版**：讲"用了什么技术、怎么实现的"

---

# 第一部分：项目是什么？

## 🗣️ 通俗版

CoursePet 是一个 **大学生口袋宠物管家** iOS App。

想象一下：你养了一只电子宠物，它不只是卖萌，而是 **真能帮你搞定大学生活里那些麻烦事** —— 

- 📅 **帮你记课表**：今天有什么课？下一节在哪上？
- 📝 **盯你的作业 DDL**：哪些作业要交了？还剩多久？
- 📦 **帮你收快递**：收到取件短信自动入库，到期了催你去拿
- 💰 **帮你记账**：花了多少？这个月吃了多少顿外卖？
- 🐾 **有一只真能动的宠物陪你**：9 个形象、8 种动作、7 帧动画，心情好会蹦跶，饿了会蹲角落
- 🤖 **有一个 AI 管家可以聊天**：问它今天有啥课、帮你加作业、帮你记账，它都能做到
- 🌅 **灵动岛 / 小组件**：锁屏就能看课表、看宠物、看 DDL
- 🌤️ **早上 7 点自动给你发天气+课表晨报**
- 👣 **走了 6000 步奖励宠物**
- 🏫 **走进教学楼附近自动报下一节课**

---

## 🔧 技术版

### 项目定位
- 平台：iOS 16.1+（iPhone 和 iPad 都支持）
- 架构：**客户端 + 服务器端 双模式**（可独立运行，也可配合）
- 客户端技术栈：Swift 5.9 + SwiftUI + 多个 Apple 原生框架
- 服务器端技术栈：Python 3 + FastAPI + PostgreSQL + pgvector

### 项目目录结构
```
CoursePet/
├── ios/                          ← iOS 客户端（Swift）
│   ├── CoursePet/                ← 主 App Target
│   │   ├── Agent/                ← AI 管家模块（23 个文件，核心！）
│   │   ├── Views/                ← 5 个主 Tab 的页面
│   │   ├── Support/              ← 9 个辅助模块（通知/天气/步数...）
│   │   ├── CoursePetApp.swift    ← App 入口
│   │   └── PetIntents.swift      ← Siri 快捷指令
│   ├── Shared/                   ← 17 个共享文件（三端共用的核心逻辑）
│   ├── CoursePetWidgets/         ← Widget 小组件扩展
│   ├── CoursePetLiveActivity/    ← 灵动岛 / Live Activity 扩展
│   ├── AppPetAssets/             ← 9 只宠物 × 8 种动作 × 7 帧 = ~500 张 PNG
│   ├── project.yml               ← XcodeGen 配置（不用手写 pbxproj）
│   ├── generate_pbxproj.py       ← Python 脚本生成 Xcode 工程
│   └── build.bat / build.sh      ← 本地构建脚本
│
├── v2-backend/coursepet-api/     ← 服务器端（Python FastAPI）
│   └── app/
│       ├── main.py               ← API 入口（634 行，所有路由）
│       ├── models.py             ← 20 张 ORM 表定义
│       ├── agent/                ← Agent 引擎（Python 版，与 iOS 端侧引擎同构）
│       │   ├── engine.py         ← ReAct 循环核心
│       │   ├── tools.py          ← 工具集
│       │   ├── prompts.py        ← System Prompt
│       │   ├── embeddings.py     ← 哈希嵌入（256 维）
│       │   ├── browser.py        ← 网页浏览（Playwright 优先，httpx 兜底）
│       │   ├── eval.py           ← 评测系统（33 条用例）
│       │   └── scheduler.py      ← 后台定时任务扫描
│       ├── config.py             ← pydantic-settings 配置
│       ├── database.py           ← SQLAlchemy + PostgreSQL
│       └── security.py           ← JWT 认证 + bcrypt 密码
│
├── pet_assets/                   ← 原始宠物帧素材（未裁剪版）
├── tools/                        ← 9 个 Python 脚本（处理图片/生成帧等）
└── codemagic.yaml                ← 云端构建配置（免签名 IPA）
```

---

# 第二部分：iOS 客户端技术详解

## 🗣️ 通俗版（Apple 技术名词翻译）

| 技术名词 | 通俗解释 | 项目里用来干嘛 |
|---------|---------|--------------|
| **SwiftUI** | 苹果的"写界面语言" | 所有页面都是用它写的，拖拖拽拽就能出界面 |
| **ActivityKit** | 灵动岛 / Live Activity | 把下节课信息显示在 iPhone 14 Pro+ 的灵动岛上 |
| **WidgetKit** | 桌面小组件 | 在手机桌面放课表/宠物的小卡片 |
| **CoreMotion** | 读取运动传感器 | 拿今天走了多少步 |
| **EventKit** | 系统日历 | 读你日历里的日程，让 AI 管家安排计划不撞车 |
| **CoreLocation** | 定位 | 查天气、进入教学楼附近提醒 |
| **UserNotifications** | 本地通知 | 上课前 15 分钟提醒你、DDL 三级轰炸 |
| **SpeechFramework** | 语音识别 | 说话就能记账 |
| **PhotosPicker** | 选照片 | 从相册选图片发给 AI 管家 |
| **App Group** | App 间共享数据 | 主 App / Widget / 灵动岛 三个模块共用一份数据 |
| **Keychain** | iOS 安全存储 | 存 API Key（删 App 重装也不丢） |
| **XcodeGen** | 自动生成 Xcode 工程 | 不用手写 .pbxproj，改 yml 就行 |
| **Codemagic** | 云端自动构建 | 推代码上去自动出 IPA |

---

## 🔧 技术版

### 2.1 项目构建与配置

#### 构建策略
```
本地开发  →  generate_pbxproj.py 生成 .xcodeproj  →  Xcode 打开调试
云端构建  →  Codemagic + XcodeGen → 免签名 IPA → AltStore 签名安装
```

**为什么用 XcodeGen 而不是直接有 .xcodeproj？**
因为 `.xcodeproj` 是 XML 格式，Git merge 会炸。用 `project.yml` 描述项目结构，XcodeGen 自动生成工程文件，多人协作不冲突。

**为什么免签名构建？**
免费 Apple ID 每周要重新签名。先构建未签名 IPA，用 AltStore 在 Windows 上签名，一次签好能用 7 天。

#### 三个 Target 架构
```
┌─────────────────────────────────────────┐
│           CoursePet（主 App）            │
│  包含：SwiftUI 界面 + 所有业务逻辑       │
│  依赖：Widget + LiveActivity            │
└──────────────┬──────────────────────────┘
               │ embed
       ┌───────┴────────┐
       ▼                ▼
┌────────────┐   ┌───────────────┐
│ Widgets    │   │ LiveActivity  │
│ 小组件扩展 │   │ 灵动岛扩展     │
└────────────┘   └───────────────┘

三个 Target 都编译 Shared/ 下的同一份代码
（避免 framework 链接的麻烦，三个二进制各编译一份）
```

### 2.2 数据共享机制

#### App Group（`group.com.coursepet.app`）
```
                    App Group 共享容器
    ┌──────────────────────────────────┐
    │  data.json（课程/作业/快递/记账）│
    │  pet_images/（宠物帧图片）       │
    └──────┬──────────────┬───────────┘
           │              │
    ┌──────┴──────┐  ┌────┴───────┐
    │ 主 App 读写 │  │ Widget/LA 读│
    └─────────────┘  └────────────┘
```

**降级策略**：免费 Apple ID 可能拿不到 App Group 权限。代码里用 `StorageLocation` 统一管理 —— 先尝试 App Group，失败自动降级到本地沙盒。

### 2.3 数据存储格式

**不使用 CoreData / SQLite，用 JSON 文件**

为什么？
- 数据量小（一个大学生一学期课表最多 50 条，作业 30 条，记账 100 条）
- JSON 人类可读，调试方便
- 跨平台（iOS / 服务器 Python 都能直接读写）
- 避免 CoreData 的复杂迁移问题

存储位置优先级：
```
1. App Group 容器/data.json  ← 三端共享
2. Bundle.main（内置示例）   ← 首次启动
3. 本地沙盒/data.json       ← App Group 降级
```

### 2.4 核心数据模型（Models.swift）

```swift
// 课程：一周几节、什么时间、在哪上、单双周
struct Course {
    id: String           // UUID
    name: String         // "高等数学"
    teacher: String      // "张老师"
    location: String     // "教学楼A-301"
    dayOfWeek: Int       // 1-7（周一到周日）
    startTime: String    // "08:00"
    endTime: String      // "09:40"
    weekParity:          // .single（单周）/ .double（双周）/ .both（每周）
    color: String        // "#FFD1C4"
}

// 作业：有 DDL 的待办
struct HomeworkItem {
    id: String
    title: String        // "第三章习题 1-10"
    courseName: String?  // 关联哪门课
    dueDate: Date?       // 截止时间
    isDone: Bool
}

// 快递：取件到了去拿
struct ParcelItem {
    id: String
    code: String         // 取件码 "3-2-0891"
    station: String      // "菜鸟驿站"
    note: String?        // "顺丰，是书"
    trackingNumber: String? // 快递单号（可选）
    pickedAt: Date?      // 取件时间（nil=未取）
}

// 记账：6 分类
struct LedgerEntry {
    id: String
    amount: Double       // 12.5
    category: String     // "餐饮"/"学习"/"交通"/"日用"/"娱乐"/"其他"
    note: String?        // "黄焖鸡米饭"
    date: Date
}

// 宠物状态
struct PetState {
    name: String         // "小狼"
    mood: Int            // 0-100（心情值）
    affection: Int       // 0-100（好感度）
    food: Int            // 剩余口粮数
    currentAction: String // idle/happy/sleep/walk...
}
```

### 2.5 SwiftUI 架构详解

#### 🎨 SwiftUI 核心模式

```
┌─────────────────────────────────────────────────────────┐
│                    @main CoursePetApp                    │
│                                                         │
│  @StateObject DataManager.shared  ← 全局单例数据源       │
│  .environmentObject(dataManager)  ← 注入到所有子视图    │
│                                                         │
│  TabView(selection: $selectedTab) {                     │
│    NavigationStack { ScheduleMainView() }        // Tab0 │
│    TodoView()                                    // Tab1 │
│    NavigationStack { FeedView() }                // Tab2 │
│    FocusView()                                   // Tab3 │
│    SettingsView()                                // Tab4 │
│  }                                                      │
│                                                         │
│  // 全局下节课悬浮条（任何 Tab 底部可见）                 │
│  NextCourseBanner().padding(.bottom, 58)                │
│                                                         │
│  // 每分钟 Timer 检查灵动岛                               │
│  .onReceive(Timer.publish(every: 60, ...))              │
│                                                         │
│  // 深链统一入口                                         │
│  .onOpenURL { handleDeepLink($0) }                      │
└─────────────────────────────────────────────────────────┘
```

**关键模式**：

| 模式 | 用法 | 代码示例 |
|------|------|---------|
| `ObservableObject` + `@Published` | 数据变化自动触发视图刷新 | `class DataManager: ObservableObject { @Published var courses: [Course] }` |
| `@EnvironmentObject` | 全局依赖注入（DataManager 跨视图共享） | `@EnvironmentObject var dataManager: DataManager` |
| `@StateObject` | 视图私有的 ObservableObject（生命周期=视图） | `@StateObject private var engine: AgentEngine` |
| `@ObservedObject` | 外部传入的 ObservableObject（视图不持有） | `@ObservedObject private var tts = AgentSpeech.shared` |
| `@State` | 视图内部状态（不跨视图共享） | `@State private var showAddSheet = false` |
| `@FocusState` | 控制输入框焦点 | `@FocusState private var inputFocused: Bool` |
| `sheet(isPresented:)` | 弹出模态层 | `.sheet(isPresented: $showAddSheet) { AddCourseView() }` |
| `confirmationDialog` | 二次确认弹框 | `.confirmationDialog("清空全部", isPresented: $showClearConfirm) { ... }` |
| `NavigationStack` | iOS 16 新导航（替代 NavigationView） | `NavigationStack { ScheduleMainView() }` |

---

#### 📅 Tab 0：课表页 SwiftUI 实现（ScheduleMainView）

**页面结构**：
```
NavigationStack {
    ScrollView {
        VStack {
            ① headerBar        // 大标题 + 问候 + 当前周数
            ② weekNavCard      // 玻璃卡：周导航（← 第 N 周 →  + 手动选开学日期）
            ③ todayBarCard     // 玻璃卡：今日课程横条 + 下节课倒计时
            ④ gridCard         // 玻璃卡：整周课表网格
        }
    }
}
```

**整周网格核心代码（绝对定位方案）**：
```swift
// 网格参数
private let dayStartMinutes = 10 * 60       // 起点 10:00
private let rowHeight: CGFloat = 52         // 每小时行高
private let timeColumnWidth: CGFloat = 38   // 左侧时间列

// 课程块定位（ZStack + overlay，绝对坐标）
ZStack(alignment: .topLeading) {
    // 时间网格线（背景）
    ForEach(0..<24) { hour in
        Rectangle().fill(Color.gray.opacity(0.1))
            .frame(height: rowHeight)
            .offset(y: CGFloat(hour * 60 - dayStartMinutes) / 60 * rowHeight)
    }
    // 课程块（每门课一个，按 dayOfWeek 水平 + 按 startTime 垂直定位）
    ForEach(todayWeekCourses) { course in
        CourseBlock(course: course)
            .frame(width: (screenWidth - timeColumnWidth) / 7 - 4)
            .offset(
                x: CGFloat(course.dayOfWeek - 1) * dayWidth + timeColumnWidth + 2,
                y: CGFloat(startMinutes - dayStartMinutes) / 60 * rowHeight
            )
    }
}
```

**马卡龙配色**（按课程名 hash 固定分配颜色，同一门课每次都是同色）：
```swift
private static let macaronColors: [Color] = [
    Color(hex: "#FFD6E0"),   // 浅粉
    Color(hex: "#C9E4FF"),   // 浅蓝
    Color(hex: "#CDF3D8"),   // 浅绿
    Color(hex: "#FFF3C4"),   // 浅黄
    Color(hex: "#E4D9FF"),   // 浅紫
    Color(hex: "#FFE3C2")    // 浅橙
]
// Color(hex:) 是自定义扩展（UIColor → SwiftUI Color 桥接）
```

**倒计时心跳**：
```swift
// 每秒刷新下节课倒计时（Timer.publish + onReceive）
@State private var lastTick: Date = Date()
.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
    lastTick = Date()
}
```

**sheet(item:) 模式编辑课程**：
```swift
// 课程块点击 → 绑定 Course? → sheet(item:) 自动弹出编辑页
@State private var editingCourse: Course?
.sheet(item: $editingCourse) { course in
    AddCourseView(course: course)  // 有 course 时是编辑，nil 时是新建
        .environmentObject(dataManager)
}
```

---

#### ✅ Tab 1：事务页 SwiftUI 实现（TodoView）

**三分段切换**：
```swift
// Toolbar 居中放 Picker（iOS 16+ .pickerStyle(.segmented) 原生分段控件）
ToolbarItem(placement: .principal) {
    Picker("事务分段", selection: $segment) {
        Text("作业").tag(Segment.homework)
        Text("快递").tag(Segment.parcel)
        Text("记账").tag(Segment.ledger)
    }
    .pickerStyle(.segmented)
}

// body 里 switch 渲染
switch segment {
case .homework: homeworkList
case .parcel:   ParcelSection()     // 独立子视图
case .ledger:   LedgerSection()     // 独立子视图
}
```

**DDL 智能排序**（Swift 高阶函数链式处理）：
```swift
private var pendingItems: [HomeworkItem] {
    dataManager.homeworks
        .filter { !$0.isDone }
        .sorted { a, b in
            // dayRank = 日期相对今天的天数偏移（负=逾期，0=今天，正=未来）
            switch (a.dueDate, b.dueDate) {
            case let (l?, r?):
                if dayRank(l) != dayRank(r) { return dayRank(l) < dayRank(r) }
                return l < r
            case (_?, nil): return true   // 有日期在前
            default:        return false
            }
        }
}
```

---

#### ❤️ Tab 2：养成页 + AI 聊天界面 SwiftUI 实现（AgentChatView）

**聊天界面布局**：
```
NavigationStack {
    VStack(spacing: 0) {
        chatList              // ScrollView + LazyVStack 气泡列表
        inputBar              // 底部输入区（文本框 + 相册 + 相机 + 发送）
    }
    .background(LinearGradient(colors: PagePalette.feed, ...))
    .navigationTitle("和\(petName)聊聊")
    .toolbar {
        ToolbarItem(.leading)  { 对话记录侧栏按钮 }
        ToolbarItem(.principal) { 悬浮形象 + 名字标签（点击换形象）}
        ToolbarItem(.trailing)  { 定时任务铃铛（含未读角标）}
        ToolbarItem(.trailing)  { 更多菜单（知识库/动态/记忆/新对话）}
    }
}
```

**聊天气泡（按 kind 分样式）**：
```swift
// 消息是枚举，SwiftUI switch 渲染对应样式
enum ChatDisplayMessageKind {
    case user           // 右对齐灰色气泡
    case assistant      // 左对齐玻璃态气泡（GlassCard）
    case toolTrace(String) // 居中小字"🔍 翻了翻今天的课表"
    case error(String)     // 红色警示
    case card(AgentCard)   // 卡片式消息（作业列表/跳转链接）
}

// SwiftUI View 里 switch：
switch msg.kind {
case .user:
    UserBubble(text: msg.text, imageData: msg.imageData)
        .frame(maxWidth: .infinity, alignment: .trailing)
case .assistant:
    PetBubble(text: msg.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()          // 液态玻璃效果
case .toolTrace(let label):
    Text(label)
        .font(.caption2)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
case .card(let card):
    AgentCardView(card: card)
}
```

**思考中动画**：
```swift
// isThinking 是 AgentEngine 的 @Published 属性
// 用点状动画（三个小圆依次缩放）
if engine.isThinking {
    HStack(spacing: 4) {
        ForEach(0..<3) { i in
            Circle()
                .fill(Color.secondary)
                .frame(width: 6, height: 6)
                .scaleEffect(isThinking ? 1.3 : 0.8)
                .animation(.easeInOut(duration: 0.6).repeatForever()
                           .delay(Double(i) * 0.15), value: isThinking)
        }
    }
}
```

**输入区多模态**：
```swift
HStack(spacing: 8) {
    // 相册（PhotosPicker）
    PhotosPicker(selection: $photoItem, matching: .images) {
        Image(systemName: "photo.on.rectangle")
    }
    // 相机（PHPickerViewController via UIViewControllerRepresentable）
    Button { showCamera = true } label: {
        Image(systemName: "camera")
    }
    // 语音（SpeechFramework via UIKit 桥接）
    Button { speech.start() } label: {
        Image(systemName: speech.isRecording ? "mic.fill" : "mic")
    }
    // 文本框 + 发送
    TextField("问问它…", text: $inputText)
    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
}
// 选图后显示 64×64 预览条
if let selectedImage {
    Image(uiImage: selectedImage)
        .resizable().scaledToFill()
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button { selectedImage = nil } label: { Image(systemName: "xmark.circle.fill") }
        }
}
```

---

#### ❤️ DataManager 架构（MVVM 核心）

```swift
// 全局单例 + ObservableObject + @Published 镜像属性
class DataManager: ObservableObject {
    static let shared = DataManager()
    
    // @Published = 自动触发 objectWillChange → SwiftUI 视图自动刷新
    @Published var courses: [Course] = []
    @Published var homeworks: [HomeworkItem] = []
    @Published var parcels: [ParcelItem] = []
    @Published var ledgerEntries: [LedgerEntry] = []
    @Published var petMood: Int = 70
    @Published var darkMode: Bool = false
    // ... 更多
    
    // 保存钩子（解耦：主 App 注入，扩展进程保持 nil）
    static var onStateSaved: (() -> Void)?
    static var onHomeworksChanged: (() -> Void)?
    static var onParcelsChanged: (() -> Void)?
    static var onCoursesChanged: (() -> Void)?
    
    // 写入流程：JSON编码 → 写磁盘 → 同步 @Published → 触发钩子
    func saveState(_ state: AppState, triggerHook: Bool = true) {
        let data = try JSONEncoder().encode(state)
        saveJSON(data)
        syncPublished(from: state)    // 同步镜像 → 视图刷新
        if triggerHook { Self.onStateSaved?() }
    }
}
```

---

### 2.6 五大 Tab 功能说明速查

#### ⏱️ Tab 3：专注页（FocusView）
- **功能**：番茄钟正计时，开始/暂停/结束
- **关键文件**：
  - `FocusActivityManager.swift` — 把专注状态推到灵动岛（"专注中 25:00"）
  - `FocusModels.swift` — 专注会话数据结构

#### ⚙️ Tab 4：设置页（SettingsView）
- **功能**：
  - 切换 9 种宠物形象
  - 暗/亮模式
  - AI 管家配置（API Key / 模型 / 服务器地址）
  - 通知开关 / 系统日历权限 / 位置提醒配置
- **关键文件**：
  - `AgentKeychain.swift` — API Key 存 Keychain

### 2.7 液态玻璃效果实现

整个 App 的 UI 采用了"液态玻璃"风格：

```swift
// 自定义 ViewModifier（GlassCard）
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)    // iOS 15+ 毛玻璃材质
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// 使用时一行搞定
SomeView()
    .glassCard()    // 等价于 .modifier(GlassCard())
```

---

# 第三部分：AI 管家模块（Agent）— 项目核心 🌟

## 🗣️ 通俗版

AI 管家是一只"会思考的电子宠物"。

你跟它说：
> "帮我把明天截止的《数学作业》加进去"

它内部会做这些事：
1. **听懂**（把你的话转成 LLM 能理解的 prompt）
2. **决定**（LLM 返回 "我要调用 add_homework 工具，参数是 标题=数学作业, 截止=明天"）
3. **执行**（代码真的把这条作业加进列表）
4. **回复**（LLM 根据执行结果生成自然语言回答）

这个循环叫 **ReAct**（Reasoning + Acting）—— 推理 → 行动 → 观察结果 → 再推理 → 再行动 → ... 直到能给你一个最终答案。

---

## 🔧 技术版

### 3.1 双模式架构

```
用户发送消息
    │
    ├── 服务器模式？（设置页填了服务器地址）
    │       │
    │       ├── YES → AgentRemoteClient.send()  → POST /agent/chat/stream → 服务器执行 ReAct
    │       │
    │       └── NO  → AgentEngine.sendOnDevice() → 端侧本地 LLM API → 本机执行 ReAct
    │
    └── 图中有 image? → base64 压缩 → 附带发送
```

**为什么要双模式？**
- 端侧模式：不依赖服务器，数据不出设备，隐私好，但用户要自己填 API Key
- 服务器模式：Key 服务端持有，支持多设备同步、长期记忆、定时任务、评测系统等高级功能

### 3.2 ReAct 循环详解

```swift
// AgentEngine.swift 的核心逻辑（简化）
func send(_ text: String) async {
    // 1. 把用户消息加入历史
    history.append(.user(text))
    
    // 2. 开始循环（最多 5 轮，防死循环）
    for round in 0..<maxRounds {
        // 3. 构造 system prompt + 历史 + 工具定义
        let messages = buildMessages(systemPrompt, history, toolDefinitions)
        
        // 4. 调 LLM
        let response = await callLLM(messages)
        
        // 5. LLM 返回了 tool_calls？
        if let toolCalls = response.toolCalls {
            // 6. 逐个执行工具
            for toolCall in toolCalls {
                let result = AgentTools.execute(toolCall.name, toolCall.arguments)
                // 7. 把工具结果作为 "tool" 消息回填历史
                history.append(.tool(result, toolCallId: toolCall.id))
            }
            // 8. 继续下一轮循环
        } else {
            // 9. LLM 返回了最终回答
            history.append(.assistant(response.text))
            displayMessages.append(.assistant(response.text))
            return  // 结束
        }
    }
    // 10. 超过 maxRounds → 强制结束
    displayMessages.append(.error("想了太久了，再问一次试试"))
}
```

### 3.3 Agent 工具集

| 工具名 | 功能 | 端侧 | 服务器 |
|--------|------|------|--------|
| `get_today_schedule` | 查今日课表 | ✅ | ✅ |
| `get_next_class` | 查下一节课 | ✅ | ✅ |
| `get_pending_homeworks` | 查未完成作业 | ✅ | ✅ |
| `add_homework` | 加作业 | ✅ | ✅ |
| `mark_homework_done` | 勾选完成作业 | ✅ | ✅ |
| `add_parcel_from_sms` | 解析短信加快递 | ✅ | ✅ |
| `add_ledger_entry` | 记一笔账 | ✅ | ✅ |
| `get_ledger_summary` | 月度汇总 | ✅ | ✅ |
| `get_steps` | 今日步数 | ✅ | ✅ |
| `get_weather` | 当前天气 | ✅ | ✅ |
| `get_pet_status` | 宠物状态 | ✅ | ✅ |
| `save_file` | 存笔记到文件柜 | ❌ | ✅ |
| `read_file` | 读文件柜笔记 | ❌ | ✅ |
| `list_files` | 列出文件柜 | ❌ | ✅ |
| `browse_url` | 浏览网页（只读） | ❌ | ✅ |
| `create_task` | 创建定时任务 | ✅(端侧) | ✅ |
| `list_tasks` | 列出定时任务 | ✅(端侧) | ✅ |
| `search_course_materials` | 检索课件资料库 | ✅(端侧RAG) | ✅(pgvector) |
| `add_course_material` | 存课件到资料库 | ✅ | ✅ |
| `get_calendar_events` | 系统日历事件 | ✅ | ✅ |
| `undo_last_write` | 撤销最近一次写入 | ❌ | ✅ |

### 3.4 LLM API 调用细节

```swift
// 构造请求（OpenAI 兼容格式）
let requestBody: [String: Any] = [
    "model": config.model,                    // 如 "deepseek-chat"
    "messages": [                             // system + 历史 + 工具定义
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": "帮我看下今天有啥课"],
        // ... 历史消息
    ],
    "tools": toolDefinitions,                 // JSON Schema 描述所有工具
    "stream": false,                          // 是否流式
    "temperature": 0.7
]

// 请求头
headers: [
    "Authorization": "Bearer \(config.apiKey)",
    "Content-Type": "application/json"
]

// URL
// 端侧模式: 用户填的（如 https://api.deepseek.com/v1/chat/completions）
// 服务器模式: POST https://你的服务器/agent/chat/stream
```

### 3.5 System Prompt 生成（AgentPromptBuilder.swift）

```
System Prompt 由以下部分动态拼接：
─────────────────────────────────────────
1. 人设："你是一只元气满满的大学生口袋宠物管家..."
2. 身份：宠物名 + 用户名 + 当前学期 + 当前周数
3. 守则（12 条）：
   - 优先用工具查，不要瞎编
   - 写操作要二次确认（如"确定要加这个作业吗？"）
   - 返回给模型看的文本要简洁
   - ...
4. 长期记忆 top 5（余弦检索）
5. 服务器模式额外注入：
   - 系统日历今日事件
   - SOUL.md 人格文件内容
```

### 3.6 长期记忆

#### 服务器模式
```
每轮对话结束 → 后台调用 LLM 提取值得记住的事实
              → 写入 memories 表（user_id 隔离）
              → 下次对话前用"当前用户消息"做 query
              → 本地哈希嵌入余弦检索 top 5
              → 注入 system prompt
```

#### 端侧模式
```
每轮对话结束 → 后台调用 LLM 提取值得记住的事实
              → 存 UserDefaults（最多 50 条 FIFO）
              → 下次对话前取最近 5 条注入
```

### 3.7 RAG 课件资料库

#### 嵌入算法（iOS 端侧 Python 同构）
```python
# 不依赖外部 embeddings API（省钱）
# 用本地哈希生成 256 维向量
def embed(text: str) -> list[float]:
    # 对每个字符做哈希 → 256 桶 → 统计分布 → L2 归一化
    ...
```

#### 检索流程
```
用户问 "微积分里的极限怎么定义"
    │
    ├── 把 query embed 成 256 维向量
    │
    ├── 服务器模式 → pgvector 余弦距离取 top 3
    │
    ├── 端侧模式 → Documents.json 内存余弦取 top 3
    │
    └── 把检索结果注入 system prompt → LLM 生成带资料来源的回答
```

### 3.8 流式输出

```
iOS 端：
    URLSession.bytes.lines → 逐行 NDJSON 解析
    每行: {"kind": "tool_trace", "text": "🔍 翻了翻今天的课表"}
         {"kind": "text", "text": "今天有 3 节课..."}
    最后: {"done": true}

服务器端：
    FastAPI StreamingResponse + async generator
    uvicorn 支持 NDJSON 流式
```

### 3.9 Agent 评测系统

```python
# 33 条固定用例，专用 __eval__ 账号
# 每条用例检查：
#   1. 工具调用断言（应该调了 get_today_schedule）
#   2. 回答关键词断言（应该提到"3 节"）
#   3. 反调用断言（不应该调 add_homework）

# 结果落 eval_runs 表，形成分数曲线
# POST /agent/eval → 全量跑
# GET /agent/eval/history → 最近 10 次分数
```

---

# 第四部分：服务器端技术详解

## 🗣️ 通俗版

服务器就是一个 **Python 写的 HTTP API**，放在一台 Linux VPS 上，通过 cloudflared 隧道暴露到公网。

它做的事：
- 注册登录（发 JWT Token 给 iOS）
- 跑 AI 管家（ReAct 循环）
- 存所有数据（课表/作业/快递/记账/对话历史）
- 定时扫描任务（"每天早上 8 点提醒我背单词"）
- 生成晨报、周报、DDL 前夜建议
- 跑评测

---

## 🔧 技术版

### 4.1 技术栈

| 组件 | 选型 | 原因 |
|------|------|------|
| Web 框架 | FastAPI | 现代、类型安全、自动生成 OpenAPI 文档 |
| 数据库 | PostgreSQL | 可靠、支持 JSON、pgvector 原生向量列 |
| ORM | SQLAlchemy 2.0 | Python 最成熟的 ORM |
| 向量检索 | pgvector | 直接在 PostgreSQL 里做向量搜索，不用额外服务 |
| 认证 | JWT + bcrypt | 轻量、无状态、密码加密存储 |
| 后台调度 | asyncio 定时循环 | 不用 Celery（太重），单进程每秒扫描 |
| 隧道 | cloudflared | 免费、不用备案域名 |
| 进程管理 | systemd | 开机自启、崩溃自动拉起 |
| LLM 协议 | OpenAI Compatible | 兼容所有主流 LLM（DeepSeek/GLM/通义/Moonshot...） |

### 4.2 PostgreSQL 数据库表（20 张）

| 表名 | 作用 |
|------|------|
| `users` | 用户注册信息 + 当前状态（步数/定位/学期开始日） |
| `courses` | 课表（user_id 隔离） |
| `homeworks` | 作业待办 |
| `parcels` | 快递取件 |
| `ledger_entries` | 记账 |
| `memories` | Agent 长期记忆（每轮对话后台提取） |
| `agent_writes` | 写操作流水（撤销功能的基础） |
| `conversation_messages` | 对话历史持久化（多设备续聊） |
| `course_docs` | RAG 课件资料库（含 pgvector 向量列） |
| `study_plans` | 复习计划 |
| `agent_tasks` | 定时/一次性任务 |
| `agent_task_results` | 任务执行结果流水 |
| `daily_briefs` | 当日晨报缓存（当日唯一） |
| `proactive_briefs` | DDL 前夜建议 / 周报等文案缓存 |
| `daily_discovers` | 每日兴趣动态（scheduler 08:05 生成） |
| `eval_runs` | Agent 评测存档 |
| `agent_documents` | 用户文件柜元信息 |

### 4.3 API 路由总览

```
/auth/*        认证（注册/登录）
/agent/chat    非流式对话（POST，返回完整消息序列）
/agent/chat/stream  流式对话（POST，NDJSON）
/agent/history 清空对话历史
/agent/soul    推送 SOUL.md 人格文件
/agent/undo    撤销最近一次写入
/agent/memory* 长期记忆管理（查/删/清空）
/agent/discover 生成兴趣动态
/agent/daily-brief 当日晨报
/agent/ddl-advice DDL 前夜分析
/agent/weekly-brief 周末周报
/agent/eval*   评测系统
/agent/tasks*  定时任务管理
/sync/*        iOS → 服务器数据同步（课表/步数/位置/课件/快递）
/health        健康检查
```

### 4.4 多用户隔离设计

```python
# 所有数据库查询强制过滤 user_id
# 防止越权访问别人的数据

@router.get("/agent/memory")
def list_memory(user: User = Depends(get_current_user)):
    # get_current_user 从 JWT 里解析 user_id
    rows = db.scalars(
        select(Memory).where(Memory.user_id == user.id)
    ).all()
    return {"items": rows}
```

### 4.5 服务器定时任务（scheduler.py）

```python
async def scheduler_loop():
    """每秒扫描一次所有活跃任务"""
    while True:
        # 1. 查所有 active 且 next_run_at <= now 的任务
        # 2. 认领：先把 next_run_at 推到下次执行时间
        #    （防止服务重启时任务丢失或重复执行）
        # 3. 用 ReAct 循环执行任务
        # 4. 结果落 agent_task_results 表
        # 5. 每日 08:05 额外触发：给每个用户生成 daily_discover
        
        await asyncio.sleep(1)
```

### 4.6 主动关怀（晨报/周报/DDL 前夜）

```python
# 晨报生成流程：
# 1. 汇总素材：今日课表 + 未完成作业 + 当前天气 + 待取快递 + 最近 3 条记忆
# 2. 调 LLM（_cheap_llm，轻量低成本模型）生成宠物口吻文案
# 3. 缓存当日唯一（brief_date 索引命中直接返回）
# 4. LLM 失败 → 模板拼接兜底 → 端侧永远有内容可排

# DDL 前夜：缓存 key = "ddl|" + 日期 + 作业清单哈希
#           同一天同样清单 → 零 LLM 开销
```

### 4.7 文件柜功能

```
每个用户独立目录: {files_root}/{user_id}/
                   ├── SOUL.md          ← 人格文件（可选）
                   └── ... 用户存的笔记文件

安全措施:
- 文件名白名单正则 + resolve() 路径越界检查
- 单文件 100KB 上限
- 读回截断 1 万字符
```

### 4.8 网页浏览（browse_url）

```
双通道设计（自动降级）：
├── Playwright + Chromium → 渲染 JS 动态页（优先）
└── httpx → 静态 HTML 抓取（Playwright 未安装时自动降级）

SSRF 防护（必过）：
├── 拒绝 127.0.0.0/8（环回）
├── 拒绝 10.0.0.0/8 / 172.16.0.0/12 / 192.168.0.0/16（内网）
├── 拒绝 169.254.0.0/16（链路本地）
└── 拒绝非 HTTP/HTTPS 协议

红线：只读浏览，不执行登录/填表/下单
HTML → Markdown 精简（保留标题/列表/链接）
```

---

# 第五部分：通知系统详解

## 🗣️ 通俗版

App 会在各种时间点给你发通知：

| 通知类型 | 什么时候发 | 怎么发 |
|---------|----------|--------|
| 🏫 上课提醒 | 每节课前 15 分钟 | 本地通知 |
| 📝 DDL 三级轰炸 | 前一天 20:00 / 当天 08:00 / 当天 18:00 | 本地通知 |
| 🌤️ 天气晨报 | 每天 07:00 | 本地通知 |
| 📦 取件提醒 | 快递入库当天 20:00 及次日 | 本地通知 |
| 📋 任务结果 | 服务器定时任务执行完毕 | 拉取 + 本地通知 |
| 🎉 成就解锁 | 达成成就条件时 | 本地通知 |

---

## 🔧 技术版

### 通知标识符体系
```
coursepet_{courseId}_{yyyyMMdd}           上课提醒（每节课独立）
coursepet_hw_{id}_{level}                 DDL 三级轰炸（level=1/2/3）
coursepet_weather_{yyyyMMdd}              天气晨报
coursepet_parcel_{id}                     取件提醒
coursepet_task_{resultId}                 任务结果
```

### 通知重建触发点
```
DataManager.onStateSaved       → 课程/设置变化 → 重建所有课程提醒
DataManager.onParcelsChanged   → 快递增删 → 重建取件提醒
DataManager.onHomeworksChanged → 作业变化 → 重建 DDL 提醒
NotificationManager.refreshAll() → 全量重建（每次保存时触发）
```

### 通知点击路由
```swift
// UNUserNotificationCenterDelegate → NotificationRouter
// 收到通知 → post NotificationCenter 事件 → ContentView.handleDeepLink

// 路由映射：
hw_ / parcel_ 前缀   → Todo（事务页）
task_ 前缀           → Feed（养成页）
geo_ 前缀            → Schedule（课表页）
focuspause           → Focus（专注页）
weather_ / brief_    → 不跳（纯通知）
其他 coursepet_      → Schedule（课表页）
```

### App 被杀后通知还生效吗？
- ✅ 上课/DDL/天气/快递：这些是系统排程的本地通知，App 被杀后 **照常触发**
- ❌ 定时任务结果：服务器执行 → App 拉取，App 被杀期间的结果 **打开时统一拉取**

---

# 第六部分：灵动岛 / Live Activity

## 🗣️ 通俗版

iPhone 14 Pro 以上有个"灵动岛"——屏幕顶端那个黑色药丸区域。CoursePet 会把以下内容推上去：

1. **下一节课**：课前 15 分钟自动显示，"⏰ 高等数学 还有 12 分钟"
2. **专注番茄钟**：开始专注后显示 "🍅 专注中 23:45"，正计时实时更新

---

## 🔧 技术版

### ActivityKit 核心概念

```
ActivityAttributes 协议 = 灵动岛的数据模型
    ├── Attributes（静态常量）  → 创建时设置，生命周期内不可变
    └── ContentState（动态状态） → 随时间变化，可 update

Activity.request()    → 启动灵动岛
Activity.update()     → 更新 ContentState
Activity.end()        → 结束灵动岛（.immediate 立即消失 / .atEnd 保留到自然结束）
```

### 灵动岛两种类型

```
┌─────────────────────────────────────────────────────────────────┐
│                  DynamicIsland（灵动岛）                         │
│                                                                 │
│  ① 紧凑收起态（compact）     ② 展开态（expanded）                │
│  ┌──────────┐               ┌─────────────────────────────┐   │
│  │ [左]宠物  │               │ [左]  [中]  [右]             │   │
│  │ [右]倒计时│               │ [底] 额外信息               │   │
│  └──────────┘               └─────────────────────────────┘   │
│                                                                 │
│  ③ 锁屏横幅（锁定屏幕上）                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  锁屏横幅自定义布局                                      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ④ 极简态（minimal）— 灵动岛最窄时的替代                       │
│  ┌───┐                                                         │
│  │🐾 │                                                         │
│  └───┘                                                         │
└─────────────────────────────────────────────────────────────────┘
```

### 课程灵动岛完整数据模型

```swift
// CourseActivityAttributes.swift
struct CourseActivityAttributes: ActivityAttributes {
    // ⚠️ ContentState 会遮蔽 ActivityAttributes 协议的同名关联类型！
    // 构造时必须用全名 CourseActivityAttributes.ContentState(...)
    public struct ContentState: Codable, Hashable {
        // 课程信息
        public var courseName: String
        public var location: String
        public var countdownText: String
        // 宠物状态（灵动岛左侧显示的真形象）
        public var petAction: String       // "nervous", "idle", "happy"...
        public var petFrame: Int           // 0-7（帧索引）
        public var charId: String          // char1-char9（形象商店切换后同步）
        public var bubbleText: String      // Agent 回复气泡（锁屏卡片显示宠物"开口"）
        // 倒计时目标时间（Text(timerInterval:) 系统驱动）
        public var courseStartTime: Date
        public var courseEndTime: Date
        public var isClassStarted: Bool    // false=倒数到上课, true=倒数到下课
    }
    
    // 常量属性（创建时固定不变）
    public var courseId: String
    public var startWeek: Int
    public var endWeek: Int
    public var weekParity: String       // "single"/"double"/"both"
}
```

### 课程灵动岛 Widget 实现（完整代码结构）

```swift
// CoursePetLiveActivity.swift
struct CoursePetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CourseActivityAttributes.self) { context in
            // ① 锁屏横幅（iOS 16+ 全屏灵动岛）
            CoursePetLiveActivityView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // ② 展开态：中间区域放完整信息
                DynamicIslandExpandedRegion(.center) {
                    CoursePetLiveActivityView(attributes: context.attributes, state: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                // ③ 紧凑态左侧：宠物真形象（LiveActivitySafePet = 扩展专用安全组件）
                LiveActivitySafePet(
                    action: context.state.petAction,
                    charId: context.state.charId,
                    size: 22          // 收起态最大 22pt
                )
            } compactTrailing: {
                // ④ 紧凑态右侧：系统驱动倒数
                // timerInterval 对未来时间 countdown 生效；Text(date, style:.timer) 只正计时
                Group {
                    if context.state.isClassStarted {
                        // 已上课 → 倒数到下课
                        Text(timerInterval: Date()...max(Date(), context.state.courseEndTime),
                             countsDown: true)
                    } else {
                        // 课前 → 倒数到上课
                        Text(timerInterval: Date()...max(Date(), context.state.courseStartTime),
                             countsDown: true)
                    }
                }
                .font(.caption2)
                .monospacedDigit()           // 数字等宽不跳动
                .foregroundColor(.orange)
                .frame(maxWidth: 52)          // 固定宽度防灵动岛抖动
            } minimal: {
                // ⑤ 极简态（灵动岛被其他 App 占用时的最小显示）
                LiveActivitySafePet(
                    action: context.state.petAction,
                    charId: context.state.charId,
                    size: 18
                )
            }
        }
    }
}
```

### 专注灵动岛（正计时 + 暂停）

```swift
// FocusLiveActivity.swift — 与课程岛不同，专注是正计时
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            // 锁屏横幅（横向布局：宠物 + 状态 + 正计时 + 语录）
            HStack(spacing: 12) {
                LiveActivitySafePet(action: ..., charId: ..., size: 44)
                VStack(alignment: .leading) {
                    Text("\(context.state.paused ? "已暂停" : "专注中") · \(context.attributes.taskName)")
                    // 系统驱动正计时：start→end 自动累加，pauseTime 暂停时停住
                    Text(timerInterval: context.state.start...context.state.end,
                         pauseTime: context.state.paused ? context.state.pauseTime : nil,
                         countsDown: false)
                }
                Spacer()
            }
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {    LiveActivitySafePet(size: 40) }
                DynamicIslandExpandedRegion(.center) {     Text("专注中 · 考研数学") }
                DynamicIslandExpandedRegion(.trailing) {   elapsedText(context) }
                DynamicIslandExpandedRegion(.bottom) {     Text("🐾 静下心来，一件一件做") }
            } compactLeading: { LiveActivitySafePet(size: 22) }
              compactTrailing: { elapsedText(context) }
              minimal: { LiveActivitySafePet(size: 18) }
        }
    }
    
    // 暂停时 pauseTime 让系统停在当前值
    @ViewBuilder
    private func elapsedText(_ context: ActivityViewContext<FocusActivityAttributes>) -> some View {
        Text(timerInterval: context.state.start...context.state.end,
             pauseTime: context.state.paused ? context.state.pauseTime : nil,
             countsDown: false)
    }
}
```

### 灵动岛启动管理器（LiveActivityManager）

```swift
// LiveActivityManager.swift — 静态方法统一管理所有课程岛
enum LiveActivityManager {
    
    /// 触发点 1：App 每分钟 Timer + 回前台 + 退后台
    static func checkAndStartIfNeeded() {
        // 1. 检查授权（⚠️ 曾经写反 guard !areActivitiesEnabled → 永远拦截）
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        // 2. 读学期开始日 → 算当前周 → 过滤单双周
        let weekNum = WeekMath.currentWeekNumber(startDateStr: semesterStart) ?? 1
        let weekCourses = ScheduleHelpers.courses(forWeek: weekNum, courses: state.courses)
        let result = ScheduleHelpers.currentAndNext(courses: weekCourses, at: Date())
        
        // 3. 下节课在 15 分钟窗口内 → 启动
        if let next = result.next, minutesUntil <= 15 && minutesUntil > 0 {
            startLiveActivity(for: next.course, startTime: next.startDate, endTime: classEnd)
        }
        // 4. 正在上课 → 也启动
        if let current = result.current { ... }
        // 5. 孤儿清理：无课可上时结束所有残留活动
        if result.current == nil && result.next == nil { endAllCourseActivities() }
    }
    
    /// 真正启动 Activity
    static func startLiveActivity(for course: Course, startTime: Date, endTime: Date) {
        // 30 秒内同一课程只允许启动一次（activities 列表更新有延迟）
        if let last = recentStartDates[course.id], Date().timeIntervalSince(last) < 30 { return }
        // 已有同课程 Activity → update 而不是 request
        if let existing = Activity<CourseActivityAttributes>.activities
            .first(where: { $0.attributes.courseId == course.id }) {
            updateLiveActivity(existing, for: course, ...)
            return
        }
        let activity = try Activity.request(
            attributes: CourseActivityAttributes(courseId: course.id, ...),
            contentState: makeState(course: course, startTime: startTime, endTime: endTime),
            pushType: nil   // 不依赖 APNs 推送
        )
        // 本地启动 5 秒定时器：阶段切换时刷新 isClassStarted
        startPeriodicUpdates(for: activity, ...)
    }
    
    /// Agent 回复上灵动岛（扩展点：宠物"开口"说话）
    static func updateAgentReply(_ text: String) {
        let activities = Activity<CourseActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        for activity in activities {
            var state = activity.contentState
            state.bubbleText = String(text.prefix(40))   // 锁屏一行放得下
            state.petAction = "happy"                     // 回话时切开心表情
            Task { try? await activity.update(using: state) }
        }
    }
}
```

### 周期性更新策略

```swift
// 每 5 秒检查一次阶段切换（课前→上课中）
// 课程结束时自动下岛（endTime 到了 → activity.end(.immediate)）
private static func startPeriodicUpdates(
    for activity: Activity<CourseActivityAttributes>,
    course: Course, startTime: Date, endTime: Date
) {
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        // 课程已结束 → 下岛
        if Date() >= endTime {
            timer?.invalidate()
            endLiveActivity(for: course.id)
            return
        }
        // 跨过 startTime → 刷新 isClassStarted（倒数目标切换）
        let nowClassStarted = Date() >= startTime
        if nowClassStarted != activity.contentState.isClassStarted {
            updateLiveActivity(activity, for: course, startTime: startTime, endTime: endTime)
        }
    }
}
```

### LiveActivitySafePet — 扩展进程安全版宠物视图

```swift
// LiveActivitySafePet.swift — 解决 PetAnimationView 在扩展进程渲染失败的问题
// 背景：扩展进程内存上限 ~30MB，多帧同步加载 + Timer + withAnimation 会撑爆渲染进程
struct LiveActivitySafePet: View {
    let action: String
    let charId: String
    let size: CGFloat
    
    var body: some View {
        Group {
            // 1. ImageIO 低内存缩略解码（先缩到 160px 再解压，防止大图撑爆内存）
            if let image = Self.loadDownsampled(action: action, charId: charId) {
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    // 轻量动画：只有 scaleEffect / offset 两种安全修饰
                    .scaleEffect(x: walkPhase ? -1 : 1, y: 1)   // 踱步转身
                    .offset(x: walkPhase ? size*0.15 : -size*0.15)
                    .scaleEffect(breathing ? 1.045 : 1.0)       // 呼吸缩放
                    .offset(y: floatY ? -size*0.05 : 0)         // 上下浮动
            } else {
                Text("🐾")   // 无帧图兜底（用户要求绝不显示程序化团子）
            }
        }
        // 动画 onAppear 启动（只用最安全的 .easeInOut + repeatForever）
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) { breathing = true }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { walkPhase = true }
        }
    }
    
    /// ImageIO 缩略解码（扩展进程低内存安全版）
    private static func loadDownsampled(action: String, charId: String) -> UIImage? {
        // 优先 App Group 容器（主 App 提前安装好的帧图）
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.coursepet.app") {
            let candidate = container
                .appendingPathComponent("Documents/PetAnimations")
                .appendingPathComponent(charId)
                .appendingPathComponent("pet_\(action)_0.png")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        // 兜底 Bundle 内置（folder reference 保持目录结构）
        if url == nil {
            url = Bundle.main.url(forResource: "pet_\(action)_0",
                                   withExtension: "png",
                                   subdirectory: "AppPetAssets/\(charId)")
        }
        // ImageIO 缩略解码
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,    // 先缩到 160px
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .map { UIImage(cgImage: $0) }
    }
}
```

### 扩展进程安全黑名单

以下在 Widget / Live Activity 扩展进程中会导致**渲染失败（整块空白）**：
```
❌ AsyncImage              → 异步加载不支持，必须 UIImage(contentsOfFile:) 同步
❌ PetAnimationView        → 多帧同步加载 + Timer + withAnimation 内存超标
❌ withAnimation(.spring()) → Spring 动画在扩展进程有兼容风险
❌ blur() / mask()         → 模糊和遮罩会导致灵动岛不渲染
❌ rotation3DEffect()     → 3D 变换不支持
❌ GeometryReader          → 在紧凑态（compact）布局里会报尺寸为零
❌ @MainActor closure      → 扩展进程严格并发，回调闭包里不能调 @MainActor
❌ Timer.publish().autoconnect() → 扩展进程不接收 Combine 定时器
```

### ContentState 命名冲突问题（坑）

```swift
// ⚠️ ActivityAttributes 协议有个叫 ContentState 的关联类型
// 如果自己的 struct 也叫 ContentState，会被遮蔽！
struct CourseActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable { ... }
    // 这里的 ContentState 同时是协议关联类型 + 自定义 struct
    // 构造时必须用全名：
    //   CourseActivityAttributes.ContentState(...)   ← ✅
    //   ContentState(...)                              ← ❌ 可能引用到协议的
}
```

---

# 第七部分：桌面小组件

## 🗣️ 通俗版

把 CoursePet 的小卡片放到手机桌面，不用打开 App 就能看到：

- **小组件（Widget）**：三种尺寸 —— 小（宠物头像+心情）/ 中（今日课表）/ 大（完整今日课表）
- **点击跳转**：点课表卡片直接打开 App 的课表页

---

## 🔧 技术版

### 三种尺寸
| 尺寸 | 展示内容 |
|------|----------|
| .systemSmall | 宠物头像 + 心情文字 |
| .systemMedium | 今日课程列表（3-4 条） |
| .systemLarge | 今日完整课表 + 宠物 |

### 数据读取
```swift
// Widget 进程和主 App 不共享内存，必须用 App Group 读同一份 data.json
// Widget 不能写，只能读
let containerURL = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.coursepet.app")!
let data = try Data(contentsOf: containerURL.appendingPathComponent("data.json"))
let state = try JSONDecoder().decode(AppState.self, from: data)
```

### 刷新时机
- 系统自动刷新（WidgetKit 策略，通常每 10-15 分钟）
- 主 App 调用 `WidgetCenter.shared.reloadAllTimelines()` 主动触发

---

# 第八部分：宠物系统详解

## 🗣️ 通俗版

9 只可选的宠物形象，每只有 8 种动作 × 7 帧动画：
```
char1 到 char9 —— 9 个不同形象
每种形象：
  pet_idle_0~7      待机动画
  pet_happy_0~7     开心蹦跶
  pet_sleep_0~7     睡觉
  pet_walk_0~7      走路
  pet_rain_0~7      淋雨
  pet_nervous_0~7   紧张
  pet_excite_0~7    兴奋
  pet_charge_0~7    吃东西
```

宠物会根据状态自动切换动作：
- mood > 80 → happy
- food < 2 → nervous（饿了）
- 晚上 22:00 后 → sleep
- 正在走路 → walk

---

## 🔧 技术版

### 帧动画加载
```swift
// 优先读 App Group 容器（主 App 提前安装好）
// 兜底读 Bundle 内置（Widget / LiveActivity 没有 App Group 时用）
func resolveFrameURL(charId: String, action: String, frameIndex: Int) -> URL? {
    // 1. 尝试 App Group
    if let groupURL = AppGroup.containerURL?
        .appendingPathComponent("pet_images/\(charId)/pet_\(action)_\(frameIndex).png"),
       FileManager.default.fileExists(atPath: groupURL.path) {
        return groupURL
    }
    // 2. 兜底 Bundle
    return Bundle.main.url(forResource: "pet_\(action)_\(frameIndex)",
                           withExtension: "png",
                           subdirectory: "AppPetAssets/\(charId)")
}
```

### 状态机（PetStateMachine.swift）
```swift
// 输入：mood / food / timeOfDay / weather / isCharging / isPlayingMusic
// 输出：当前应该播放哪个 action 的动画
func decideAction(mood: Int, food: Int, hour: Int, weather: Weather) -> String {
    if hour >= 22 || hour < 6 { return "sleep" }
    if food <= 2 { return "nervous" }
    if mood >= 80 { return "happy" }
    if mood <= 20 { return "weak" }
    if weather.isRaining { return "rain" }
    return "idle"
}
```

### 步数奖励（StepCounter.swift）
```
当日步数 ≥ 6000 → +10 EXP + 1 粮（UserDefaults 按日重置）
当日步数 ≥ 10000 → 再 +20 EXP + 2 粮
奖励自动解锁，成就墙可见
```

### 帧图片安装
```
App 首次启动 → PetAssetInstaller.installIfNeeded()
  → Bundle 内置的 pet_images/char1~9 全部帧图
  → 拷贝到 App Group 容器
  → 之后 Widget / LiveActivity 都从这里读真实形象
  → 已安装过则跳过（幂等）
```

---

# 第九部分：其他辅助功能

## 9.1 天气（WeatherManager.swift）
```
数据源：Open-Meteo（免费、不用 Key、支持国内）
缓存：经纬度存 UserDefaults（weather.lat / weather.lon）
请求：https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...&current=temperature_2m,weather_code
降级：无定位权限时返回 "天气未知"
```

## 9.2 系统日历（EventKitManager.swift）
```
读取：EventKit（EKEventStore）
返回格式："今天 14:00-15:30 线性代数；明天 09:00-10:30 英语"
权限：未授权返回空串，绝不主动弹窗
用途：注入 System Prompt → Agent 安排计划时不撞车
```

## 9.3 位置提醒（LocationReminderManager.swift）
```
技术：CoreLocation + CLCircularRegion（地理围栏，100-500 米）
触发：走进设置的提醒点 → 本地通知报下一节课
限制：每个地点每天最多提醒一次
自愈：App 被杀后围栏失效 → 冷启动/回前台时 bootstrap() 重建
上限：最多 5 个提醒点
```

## 9.4 语音记账（SpeechLedger.swift）
```
技术：SpeechFramework（端侧识别）
流程：点麦克风 → 说"午饭黄焖鸡 18 块" → 端侧识别 → 正则提取金额和分类 → 自动填入
端侧识别优先（iOS 14+ 支持），不依赖网络
```

## 9.5 快递短信解析（ParcelSmsParser.swift）
```
输入："【菜鸟驿站】您的顺丰快递已到达3号楼菜鸟驿站，取件码3-2-0891"
输出：{code: "3-2-0891", station: "3号楼菜鸟驿站", trackingNumber: null}
算法：正则匹配取件码（\d-\d-\d{4,6}）+ 驿站名（"XX驿站"/"XX菜鸟"/"XX快递"）
```

## 9.6 快捷指令 / Siri（PetIntents.swift）
```swift
// App Intents 框架
// 用户可以在快捷指令里调用：
// - "今日课表" → 问一下 Siri，Siri 调用 CoursePet 的 App Intent
// - "加作业" → 通过快捷指令参数传作业标题

// 实现：让 AgentEngine.askOnce() 跑一轮 ReAct
@MainActor
func askOnce(_ text: String) async -> String {
    await send(text)
    // 从新增消息里提取最后一条助手回复
    return displayMessages.last { $0.kind == .assistant }?.text ?? "..."
}
```

## 9.7 URL Scheme（coursepet://）
```
coursepet://schedule     → 跳课表 tab
coursepet://todo         → 跳事务 tab
coursepet://feed         → 跳养成 tab
coursepet://focus        → 跳专注 tab
coursepet://settings     → 跳设置 tab
coursepet://parcel?text= → 事务 tab + 预填取件短信解析

// 触发源：
// - Widget / Live Activity 点击
// - 聊天里的跳转卡片（美团外卖 meituanwaimai://）
// - 快捷指令自动化
// - 通知点击路由
```

---

# 第十部分：部署流程

## 10.1 iOS 构建（Codemagic）
```
git push → Codemagic 自动构建（mac_mini_m2）
  → brew install xcodegen
  → xcodegen generate（project.yml → .xcodeproj）
  → xcodebuild build（CODE_SIGNING_ALLOWED=NO）
  → 打包 CoursePet-unsigned.ipa
  → 打包 CoursePet-simulator.zip（Appetize.io 预览用）
  → 产物下载 → AltStore 签名 → 安装到手机
```

## 10.2 服务器部署
```bash
# VM 上的一次性初始化
sudo dnf install python311 python311-pip postgresql postgresql-server
sudo systemctl start postgresql
sudo -u postgres psql -c "CREATE DATABASE coursepet"
sudo -u postgres psql -c "CREATE EXTENSION vector"  # pgvector

# 安装依赖
cd v2-backend/coursepet-api
pip install -r requirements.txt

# 初始化文件柜目录（Muse 式文件系统）
sudo mkdir -p /data/users
sudo chown zhr /data/users

# .env 配置 LLM API Key
echo "llm_api_key=sk-xxx" >> .env

# systemd 开机自启
sudo cp coursepet-api.service /etc/systemd/system/
sudo systemctl enable --now coursepet-api

# cloudflared 隧道（暴露到公网）
cloudflared tunnel --url http://localhost:8000
# 获取 URL：bash ~/myurl.sh
```

## 10.3 iOS 配置服务器模式
```
App → 设置 → AI 管家 → 服务器模式
填：
  地址：https://your-tunnel-url.trycloudflare.com
  用户名：你注册的用户名
  密码：你注册的密码
  → 保存
→ 客户端自动切服务器模式，端侧 ReAct 引擎停用
```

---

# 附录 A：架构模式总结

```
┌──────────────────────────────────────────────────────────────────┐
│                        CoursePet                                  │
│                                                                  │
│  ┌─────────────┐   ┌──────────────┐   ┌─────────────────────┐   │
│  │  SwiftUI App │   │ Agent 引擎    │   │  Widget/LA 扩展     │   │
│  │  (5 Tab 页) │──▶│ (ReAct 循环) │──▶│ (共享 JSON 数据)     │   │
│  └──────┬──────┘   └──────┬───────┘   └─────────────────────┘   │
│         │                  │                                      │
│         ▼                  ▼                                      │
│  ┌─────────────┐   ┌──────────────┐   ┌─────────────────────┐   │
│  │ 本地通知     │   │ 服务器模式    │   │  LLM API（外部）    │   │
│  │ 灵动岛       │   │ FastAPI/PG   │   │ DeepSeek/GLM/...   │   │
│  │ 小组件       │   │ JWT 认证     │   │ OpenAI Compatible   │   │
│  └─────────────┘   └──────────────┘   └─────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘

核心设计模式：
├── ReAct 循环（推理→行动→观察→再推理）
├── 双模式架构（端侧独立 / 服务器增强）
├── 数据同源（iOS 主写，服务器同步，双向收敛）
├── App Group + JSON（三端共享数据）
├── System Prompt 动态注入（记忆/日历/人格文件）
├── 哈希嵌入本地 RAG（不依赖外部 embeddings API）
├── 降级策略（LLM 失败→模板兜底；App Group 失败→本地沙盒）
└── 进程解耦（DataManager 静态钩子通知扩展模块）
```

---

# 附录 B：关键数字速查

| 指标 | 数值 |
|------|------|
| Swift 文件数 | 72 |
| Python 文件数 | 29 |
| PostgreSQL 表数 | 20 |
| iOS 最低版本 | 16.1 |
| Swift 版本 | 5.9 |
| App Group | group.com.coursepet.app |
| Max ReAct 轮次 | 5 |
| Keep History 轮次 | 6 |
| 宠物形象数 | 9 |
| 宠物动作数 | 8 |
| 每动作帧数 | 7 |
| 免费模型推荐 | GLM-4.7-Flash（智谱） |

---

> 💡 这份文档覆盖了项目的所有主要技术点。每个功能都可以在对应的 Swift / Python 文件里找到实现代码。建议对照着文件看，会理解得更快。
