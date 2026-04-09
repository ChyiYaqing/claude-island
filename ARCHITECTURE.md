# Claude Island 架构与代码逻辑

> 面向 macOS 开发小白的完整讲解。随代码更新持续维护。
>
> 最后更新：2026-04-09

---

## 一、核心类比

**把 Claude Island 想象成一个快递调度室，贴在你家门框顶上（MacBook 的 Notch 缺口）。**

- Claude Code CLI = 快递员，在外面跑任务
- 每次快递员要做重要操作（执行工具、需要权限），就发消息给调度室
- 调度室（Claude Island）贴着门框显示状态，有事就弹出来告诉你
- 你可以直接在门框上点"同意"或"拒绝"，不用切换到终端

---

## 二、整体架构图

```
┌─────────────────────────────────────────────────────────────┐
│                     macOS 系统                               │
│                                                             │
│  ┌──────────────────┐    Unix Socket      ┌─────────────┐  │
│  │  Claude Code CLI │ ──────────────────► │ ClaudeIsland│  │
│  │  (快递员)        │ /tmp/claude-island  │ .app (调度室)│  │
│  │                  │       .sock         │             │  │
│  │  运行hook脚本    │                     │             │  │
│  │  (python)        │◄────────────────── │  等待决策   │  │
│  └──────────────────┘    JSON响应        └─────────────┘  │
│          │                                      │          │
│          ▼                                      ▼          │
│  ~/.claude/projects/                    屏幕顶部 Notch      │
│  ├── project-A/                         ┌─────────────┐   │
│  │   └── session.jsonl  (对话记录)      │  🦀  ···  ≡ │   │
│  └── project-B/                         └─────────────┘   │
│      └── session.jsonl                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 三、Xcode 工程结构

```
claude-island/
├── ClaudeIsland.xcodeproj/     ← Xcode 工程配置（project.pbxproj 是 XML）
│
└── ClaudeIsland/               ← 实际源代码
    ├── App/                    ← 程序入口与生命周期
    │   ├── ClaudeIslandApp.swift   ← @main 入口
    │   ├── AppDelegate.swift       ← 启动初始化
    │   ├── WindowManager.swift     ← 窗口创建与管理
    │   └── ScreenObserver.swift    ← 屏幕变化监听
    │
    ├── Core/                   ← 核心状态与几何计算
    │   ├── NotchViewModel.swift    ← Notch 开关/内容状态
    │   ├── NotchGeometry.swift     ← 坐标系与命中检测
    │   ├── NotchActivityCoordinator.swift
    │   ├── ScreenSelector.swift
    │   └── Settings.swift
    │
    ├── Models/                 ← 纯数据结构（无副作用）
    │   ├── SessionState.swift      ← 单个 Claude session 的完整状态
    │   ├── SessionPhase.swift      ← 状态机枚举
    │   ├── SessionEvent.swift      ← 所有事件类型
    │   ├── ChatMessage.swift
    │   └── ToolResultData.swift
    │
    ├── Services/               ← 业务逻辑
    │   ├── Hooks/
    │   │   ├── HookSocketServer.swift  ← Unix Socket 服务端
    │   │   └── HookInstaller.swift     ← 自动安装 hook 脚本
    │   ├── State/
    │   │   └── SessionStore.swift      ← 中央状态管理（actor）
    │   ├── Session/
    │   │   ├── ClaudeSessionMonitor.swift  ← UI 层桥接
    │   │   └── ConversationParser.swift    ← 解析 .jsonl 文件
    │   ├── Usage/
    │   │   └── UsageService.swift      ← 计划用量限制（Anthropic API）
    │   ├── Tmux/               ← tmux 集成
    │   └── Window/             ← 窗口聚焦（yabai）
    │
    ├── UI/                     ← SwiftUI 界面
    │   ├── Views/
    │   │   ├── NotchView.swift         ← 主界面（灵动岛）
    │   │   ├── ClaudeInstancesView.swift   ← session 列表
    │   │   ├── NotchMenuView.swift     ← 设置菜单
    │   │   └── ChatView.swift          ← 对话历史
    │   └── Components/
    │       ├── NotchHeaderView.swift   ← 螃蟹图标等
    │       ├── StatusIcons.swift       ← 像素风格状态图标
    │       ├── UsageLimitsView.swift   ← 用量百分比显示
    │       └── ProcessingSpinner.swift
    │
    ├── Events/                 ← 全局鼠标/键盘事件监听
    └── Resources/
        └── ClaudeIsland.entitlements  ← 权限声明（非沙盒）
```

### Xcode 日常工作流

```
1. 打开 ClaudeIsland.xcodeproj
2. Scheme: ClaudeIsland  |  目标: My Mac
3. Cmd+R         → 编译并运行
4. Cmd+B         → 仅编译（提交前检查）
5. Cmd+Shift+K   → Clean Build（遇到假报错时）
6. Cmd+Option+Return → 打开 SwiftUI Canvas 预览
```

---

## 四、启动流程

### 第 1 步：程序入口

```swift
// ClaudeIslandApp.swift
@main
struct ClaudeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }  // 没有标准窗口
    }
}
```

`@main` 是程序入口标记。`Settings { EmptyView() }` 是空壳——这个 App 不用系统默认窗口，一切由 `AppDelegate` 手动掌控。

### 第 2 步：AppDelegate 初始化

```
applicationDidFinishLaunching() 顺序执行：
┌──────────────────────────────────────────────┐
│ 1. ensureSingleInstance()  防止开两个实例     │
│ 2. Mixpanel.initialize()   匿名使用统计       │
│ 3. HookInstaller.installIfNeeded()           │ ← 写 hook 脚本到 ~/.claude/hooks/
│ 4. setActivationPolicy(.accessory)           │ ← 不在 Dock 显示
│ 5. WindowManager.setupNotchWindow()          │ ← 创建透明悬浮窗
│ 6. ScreenObserver 监听屏幕变化               │
│ 7. Sparkle 检查更新（启动 + 每小时）         │
└──────────────────────────────────────────────┘
```

### 第 3 步：悬浮窗口如何"贴"在 Notch 上

```
窗口属性：
  宽度   = 屏幕全宽
  高度   = Notch 区域 + 展开空间
  背景   = 完全透明
  层级   = .statusBar（悬浮在所有窗口之上）
  默认   = ignoresMouseEvents = true（鼠标穿透，不干扰正常使用）
  悬停时 = ignoresMouseEvents = false（响应交互）
```

---

## 五、核心数据流

```
Claude Code 运行某任务
        │
        ▼
~/.claude/hooks/claude-island-state.py（hook 脚本）
        │  读取事件类型、session_id、工具名等
        ▼
Unix Socket → /tmp/claude-island.sock
        │  发送 JSON
        ▼
HookSocketServer.swift（监听 Socket）
        │  解码为 HookEvent
        ▼
SessionStore.process(.hookReceived(event))
        │  actor 保证线程安全，更新 sessions 字典
        ▼
sessionsSubject.send(新状态)   ← Combine Publisher
        │
        ▼
ClaudeSessionMonitor（@MainActor）
        │  @Published var instances 更新
        ▼
NotchView（SwiftUI）自动重绘 UI
```

---

## 六、SessionPhase 状态机

```
           用户发送消息
                │
          ┌─────▼─────┐
    ┌────►│   idle    │◄────────────────────┐
    │     └─────┬─────┘                     │
    │           │ UserPromptSubmit           │
    │     ┌─────▼──────────┐                │
    │     │  processing    │                │
    │     └─────┬──────────┘                │
    │           │ PermissionRequest          │
    │   ┌───────▼────────────────┐          │
    │   │  waitingForApproval    │          │ SessionEnd
    │   └───────┬────────────────┘          │
    │           │ 用户批准                  │
    │     ┌─────▼──────────┐                │
    │     │ waitingForInput │───────────────┘
    │     └─────────────────┘
    │           │ 用户回复
    └───────────┘

    另有: compacting（上下文压缩中）
         ended（session 已归档）
```

---

## 七、权限审批的"挂起等待"机制

这是最精妙的设计——Claude 被挂起直到你点按钮：

```
Claude 要执行危险操作（如 rm -rf）
            │
            ▼
    hook脚本发送 PermissionRequest
            │
     ┌──────▼──────────────────────────────┐
     │  socket 连接保持开着，脚本阻塞等待  │ ← 最长 5 分钟
     └──────┬──────────────────────────────┘
            │
            ▼
    HookSocketServer 存入 pendingPermissions
            │
            ▼
    Notch 弹出，显示 [Deny] [Allow]
            │
            ▼ 用户点击 Allow
    respondToPermission(decision: "allow")
            │
            ▼
    向 socket 写入 {"decision":"allow"}
            │
            ▼
    hook脚本收到响应，解除阻塞
            │
            ▼
    Claude 继续执行
```

---

## 八、SwiftUI 声明式 UI

macOS 传统用 `NSView` 手动布局，这个项目用 **SwiftUI**（类似 React）。

```swift
// 不写"如何画"，写"数据是什么就显示什么"
var body: some View {
    if isProcessing {
        ProcessingSpinner()           // 数据变 → 自动重绘
    } else if hasWaitingForInput {
        ReadyForInputIndicatorIcon()
    }
}
// 数据变了？SwiftUI 自动 diff 并更新 UI
```

### NotchView 布局层次

```
NotchView
└── VStack
    ├── headerRow（始终可见，高度 = Notch 原始高度）
    │   ├── 左：ClaudeCrabIcon + 权限指示图标（amber）
    │   ├── 中：黑色填充 or 已展开时的标题内容
    │   │         └── UsageLimitsView: "5h: 14% · W: 36%"  ← 新增
    │   └── 右：ProcessingSpinner（处理中）or 对勾（完成）
    │
    └── contentView（仅展开时可见）
        ├── ClaudeInstancesView  ← session 列表
        ├── NotchMenuView        ← 设置页
        └── ChatView             ← 对话历史
```

---

## 九、Plan Usage Limits（新功能，2026-04-09）

从 Anthropic OAuth API 获取 5 小时和 7 天的用量百分比：

```
App 打开 / Notch 展开
        │
        ▼
UsageService.refresh()
        │
        ├── 读本地缓存（5分钟内有效）
        │   ~/.claude/.claude-island-usage-cache.json
        │
        └── 缓存过期 → 读 macOS Keychain
                │  Service: "Claude Code-credentials"
                ▼
            accessToken: "eyJ..."
                │
                ▼
            GET https://api.anthropic.com/api/oauth/usage
            Headers:
              Authorization: Bearer {token}
              anthropic-beta: oauth-2025-04-20
                │
                ▼
            响应：
            {
              "five_hour": { "utilization": 14.0 },  ← 14%
              "seven_day":  { "utilization": 36.0 }  ← 36%
            }
                │
                ▼  除以 100 归一化为 0.0–1.0
            @Published var data = UsageLimitData(...)
                │
                ▼
            NotchView 重绘 header
            显示 "5h: 14% · W: 36%"

颜色规则：
  < 50%  → 白色（正常）
  50–80% → 琥珀色（注意）
  ≥ 80%  → 红色（即将到限）
```

相关文件：
- `Services/Usage/UsageService.swift` — 认证 + API + 缓存
- `UI/Components/UsageLimitsView.swift` — 百分比展示组件
- `UI/Views/NotchView.swift` — `openedHeaderContent` 中引用

---

## 十、并发模型

```
线程模型：
┌─────────────────────────────────────────────────┐
│  Main Thread (@MainActor)                        │
│  ├── NotchView、ClaudeInstancesView（SwiftUI）   │
│  ├── ClaudeSessionMonitor（@Published 更新）     │
│  └── NotchViewModel（鼠标事件、动画）            │
│                                                  │
│  Actor（SessionStore）                           │
│  └── 自动串行化，任何线程调用都安全              │
│                                                  │
│  Background (DispatchQueue / Task.detached)      │
│  ├── HookSocketServer（Socket I/O）              │
│  ├── UsageService.computeWeeklyUsage()           │
│  └── ConversationParser（文件读取）              │
└─────────────────────────────────────────────────┘

数据从后台 → UI 的路径：
  后台更新 → sessionsSubject.send()
  → .receive(on: DispatchQueue.main)
  → @Published 更新
  → SwiftUI 重绘
```

---

## 十一、常见 Gotcha

### Gotcha 1：UI 必须在主线程更新

```swift
// ❌ 崩溃：在后台线程更新 UI
DispatchQueue.global().async {
    self.label = "新文本"
}

// ✅ 正确方案一：@MainActor 标记类
@MainActor class NotchViewModel: ObservableObject { ... }

// ✅ 正确方案二：显式切换
await MainActor.run { self.label = "新文本" }
```

### Gotcha 2：`@Published` 数组需要整体替换才触发更新

```swift
// ❌ UI 不更新
self.instances[0].name = "新名字"

// ✅ 触发更新
self.instances = newArray
```

### Gotcha 3：SourceKit 误报红色错误

Xcode 的代码分析引擎（SourceKit）有时会误报"找不到类型"，但实际编译完全没问题。
验证方法：运行 `xcodebuild -scheme ClaudeIsland -configuration Debug 2>&1 | tail -3`，看到 `BUILD SUCCEEDED` 则无问题。

修复方法：`Cmd+Shift+K`（Clean Build）→ 重启 Xcode。

### Gotcha 4：macOS Keychain 访问需要非沙盒

`UsageService` 用 `SecItemCopyMatching` 读 Keychain，要求 App 非沙盒。
本项目 `ClaudeIsland.entitlements` 已设置 `com.apple.security.app-sandbox = false`，因此可用。

---

## 十二、关键第三方依赖

| 依赖 | 用途 |
|------|------|
| Sparkle | 应用自动更新框架 |
| Mixpanel | 匿名使用数据统计 |
| Security.framework | macOS Keychain 读取 |
| Combine | 响应式数据流（Publisher/Subscriber） |
| SwiftUI | 声明式 UI 框架 |

---

## 十三、本地数据文件

| 路径 | 内容 |
|------|------|
| `~/.claude/hooks/claude-island-state.py` | Claude Code hook 脚本（App 自动安装） |
| `~/.claude/projects/**/*.jsonl` | 各 session 的对话记录（JSONL 格式） |
| `~/.claude/stats-cache.json` | Claude Code 的历史用量统计缓存 |
| `~/.claude/.claude-island-usage-cache.json` | Claude Island 的 API 用量缓存（5分钟） |
| `/tmp/claude-island.sock` | App 运行期间的 Unix Socket |
