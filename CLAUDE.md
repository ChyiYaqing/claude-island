# Claude Island — CLAUDE.md

项目规范与开发指南，供 Claude Code 在此仓库工作时遵守。

---

## 项目概述

**Claude Island** 是一个 macOS 菜单栏应用，以灵动岛（Dynamic Island）风格在 MacBook Notch 上展示 Claude Code CLI 的 session 状态。

- **Bundle ID**: `com.celestial.ClaudeIsland`
- **当前版本**: 1.2.1 (build 3)
- **最低系统**: macOS 15.0+
- **语言**: Swift 5.9 + SwiftUI
- **无测试目标**（无 XCTest，构建通过即验证）

---

## 构建与验证

```bash
# 编译（唯一验证手段，无测试）
xcodebuild -scheme ClaudeIsland -configuration Debug -quiet

# 检查是否真的成功
xcodebuild -scheme ClaudeIsland -configuration Debug 2>&1 | tail -1
# 期望输出: ** BUILD SUCCEEDED **
```

提交前必须确保零 error。SourceKit 的红色报错可以忽略，以 `xcodebuild` 结果为准。

---

## 目录结构

```
ClaudeIsland/
├── App/          程序入口、AppDelegate、窗口管理
├── Core/         NotchViewModel（UI状态）、NotchGeometry（坐标）
├── Models/       纯数据结构：SessionState、SessionPhase、SessionEvent
├── Services/
│   ├── Hooks/    Unix Socket 服务端 + hook 脚本安装
│   ├── State/    SessionStore（actor，唯一状态变更入口）
│   ├── Session/  ClaudeSessionMonitor（UI桥接）、ConversationParser
│   ├── Usage/    UsageService（Anthropic OAuth API 用量查询）
│   ├── Tmux/     tmux 集成
│   └── Window/   yabai 窗口聚焦
├── UI/
│   ├── Views/    NotchView、ClaudeInstancesView、ChatView、NotchMenuView
│   └── Components/  图标、UsageLimitsView、MarkdownRenderer 等
└── Events/       全局鼠标/键盘监听
```

---

## 核心设计约定

### 状态管理
- **`SessionStore`（actor）** 是唯一的状态变更入口。所有 session 状态改变必须通过 `SessionStore.process(_:)` 完成，禁止从外部直接修改。
- **`ClaudeSessionMonitor`（`@MainActor`）** 是 UI 层的桥接，订阅 `SessionStore.sessionsPublisher` 并暴露 `@Published` 属性给 SwiftUI。
- **`NotchViewModel`（`@MainActor`）** 只管 UI 状态（开关/内容类型），不持有业务数据。

### 线程规则
- UI 更新必须在主线程（`@MainActor` 或 `DispatchQueue.main`）。
- 文件 I/O、Socket、网络请求用 `Task.detached(priority: .utility)` 或 `actor`。
- Combine 流从后台到 UI 必须经 `.receive(on: DispatchQueue.main)`。

### SwiftUI 模式
- 用声明式描述状态，不写命令式刷新。
- `@Published` 数组需整体替换才触发 UI 更新（不能只改元素）。
- 避免在 View 中放业务逻辑，抽到 ViewModel 或 Service。

---

## 关键文件速查

| 需求 | 文件 |
|------|------|
| 修改 Notch 展开/收起逻辑 | `Core/NotchViewModel.swift` |
| 修改 Notch 外观/动画 | `UI/Views/NotchView.swift` |
| 添加新的 hook 事件类型 | `Services/Hooks/HookSocketServer.swift` + `Models/SessionEvent.swift` |
| 修改 session 状态机 | `Models/SessionPhase.swift` + `Services/State/SessionStore.swift` |
| 修改 session 列表行 | `UI/Views/ClaudeInstancesView.swift` |
| 修改设置菜单 | `UI/Views/NotchMenuView.swift` |
| 修改用量百分比展示 | `Services/Usage/UsageService.swift` + `UI/Components/UsageLimitsView.swift` |
| 修改 hook 安装脚本 | `Services/Hooks/HookInstaller.swift` |

---

## 外部依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| Sparkle | 2.9.1 | 应用自动更新 |
| swift-markdown | 0.7.3 | Markdown 渲染（对话历史） |
| Mixpanel | master | 匿名统计（App启动、Session启动） |
| jsonlogic | 1.2.4 | JSON Logic 规则 |

---

## 本地数据文件

| 路径 | 说明 |
|------|------|
| `~/.claude/hooks/claude-island-state.py` | Hook 脚本（App 自动安装） |
| `~/.claude/projects/**/*.jsonl` | Session 对话记录 |
| `~/.claude/stats-cache.json` | Claude Code 历史用量缓存 |
| `~/.claude/.claude-island-usage-cache.json` | Claude Island API 用量缓存（5 分钟 TTL） |
| `/tmp/claude-island.sock` | 运行期 Unix Socket |

---

## 版本号管理

版本号在 `ClaudeIsland.xcodeproj/project.pbxproj` 中维护：
- `MARKETING_VERSION` — 对外版本（如 `1.2.1`）
- `CURRENT_PROJECT_VERSION` — Build 号（整数递增）

改版本时两处都要同步更新（Debug + Release 配置各一份）。

---

## 常见陷阱

1. **SourceKit 误报**：IDE 红色报错不等于编译失败，以 `xcodebuild` 为准。
2. **Keychain 访问**：`UsageService` 用 `SecItemCopyMatching` 读取 Claude Code 的 OAuth token，依赖 `app-sandbox = false`，不可开启沙盒。
3. **ignoresMouseEvents**：Notch 窗口默认穿透鼠标，悬停/展开时才切换为可交互。修改此逻辑需同时处理"点击穿透"（quit 按钮等）。
4. **`@Published` 数组**：直接改数组元素不触发 SwiftUI 更新，必须赋值整个数组。
5. **Permission Socket 挂起**：`PermissionRequest` hook 会阻塞 Claude 进程等待响应（最长 5 分钟），务必在所有代码路径上都关闭 socket。

---

## 参考文档

- `ARCHITECTURE.md` — 完整架构与数据流图解（面向新开发者）
- `README.md` — 功能介绍与安装说明
