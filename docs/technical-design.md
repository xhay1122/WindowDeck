# WindowDeck 技术方案（macOS）

> 状态：v0.2 · 2026-11-05（已按本方案完成首版实现，实现中的调整见第 24 节）
> 范围：仅 macOS。Windows 版本暂不纳入。

---

## 1. 背景与目标

macOS 自带的三指上滑（调度中心 / Mission Control）与三指下滑（App Exposé）在窗口多、标题相似时难以区分窗口，且不能直接在预览里关闭 / 收起窗口。WindowDeck 用一个常驻菜单栏的应用替换这两个手势的效果。

### 1.1 功能目标

| 编号 | 功能 | 说明 |
|---|---|---|
| F1 | 三指上滑 → **应用牌堆（Deck 视图）** | 按应用分组，同一应用的多个窗口堆叠在一起，每张卡片露出标题和部分窗口内容 |
| F2 | 三指下滑 → **当前应用窗口（Exposé 视图）** | 类似 App Exposé，平铺列出当前（前台）应用的全部窗口 |
| F3 | 窗口卡片红绿灯 | 卡片上提供 关闭 / 收起（最小化）/ 绿色按钮（全屏或缩放，可配置）三个操作 |
| F4 | 标题可调 | 标题字号、字重、最大行数、截断方式可配置，支持大字号与长标题完整展示 |
| F5 | 可配置不展示窗口内容 | "仅标题"模式：不显示缩略图，只展示应用 + 窗口标题列表 |
| F6 | 快捷键 | 两个视图都可配置全局快捷键，**默认不配置** |
| F7 | 设置与权限引导 | 菜单栏入口、设置界面、权限检测与引导、手势冲突检测 |

### 1.2 非目标（当前版本不做）

- 不复刻系统调度中心"真实窗口缩放飞入"的 WindowServer 级动画（第三方无法实现），改用"缩略图从窗口真实位置飞入"的近似效果。
- 不做 Space（桌面）管理（新建 / 删除 / 拖拽窗口到其他 Space）。
- 不上架 Mac App Store（辅助功能 API 与私有框架与 App Sandbox 不兼容）。
- 不支持 Windows / Linux。

### 1.3 设计原则

1. **打开要快**：窗口目录在后台由事件驱动持续维护，触发时只做"读快照 + 布局 + 渲染"，不现场枚举。
2. **私有 API 可降级**：所有私有符号运行时通过 `dlsym` 解析，缺失时自动关闭对应能力，绝不崩溃。
3. **一个卡死的应用不能拖垮全局**：所有 Accessibility 调用设置超时，并按应用隔离执行队列。
4. **核心逻辑可测试**：布局、手势识别、标题格式化、配置迁移放在纯 Swift 包里，不依赖 AppKit，可 `swift test`。
5. **独立实现**：可参考公开资料中的思路，但不复制任何第三方 GPL 代码；引入的依赖仅限 MIT / BSD 类许可。

---

## 2. 运行环境与技术选型

| 项 | 选择 | 说明 |
|---|---|---|
| 最低系统 | macOS 14.0 | `SCScreenshotManager`（单帧截图）从 14.0 起可用 |
| 开发 / 测试系统 | macOS 27.x | 本机 27.0.1 |
| 语言 | Swift 6（strict concurrency） | |
| UI | 覆盖层：AppKit + Core Animation；设置界面：SwiftUI | 覆盖层卡片多、图片大，用 `CALayer.contents` 直接放 `CGImage`，性能可控；设置页用 SwiftUI 开发效率高 |
| 工程 | SwiftPM：根 `Package.swift`（App 可执行目标）+ 本地包 `WindowDeckCore`，`scripts/build-app.sh` 组装 `.app` | 平台无关逻辑放 Package，便于单测；不依赖完整 Xcode |
| 依赖 | 无第三方依赖。全局快捷键用 Carbon `RegisterEventHotKey` + 自绘录制控件 | 可选：`Sparkle`（MIT，自动更新，M5 再考虑） |
| 分发 | Developer ID 签名 + Hardened Runtime + 公证 | 不启用 App Sandbox |
| 应用形态 | `LSUIElement = YES`（无 Dock 图标，仅菜单栏） | |

> 环境注意：本机 `xcode-select -p` 指向 CommandLineTools（Swift 6.4），完整 Xcode 为 16.2（Swift 6.0）。工程改为纯 SwiftPM 后无需切换：
> - SwiftPM 6.4 默认的 swift-build 后端在 CLT 下无法初始化，统一使用 `--build-system native`；
> - CLT 不含 SwiftUI 宏插件，而新版 SDK 中 `@State` 是宏，代码中直接使用 `State` 属性包装器类型；
> - native 后端找不到 CLT 中的 Testing.framework，`scripts/test-core.sh` 显式传入框架路径。

### 2.1 系统 API 一览

| 能力 | API | 公开 / 私有 |
|---|---|---|
| 运行中应用 | `NSWorkspace.runningApplications` + 通知 | 公开 |
| 窗口枚举 / 属性 / 操作 | `AXUIElement*`、`AXObserver*` | 公开（需辅助功能权限） |
| AX 元素 → `CGWindowID` | `_AXUIElementGetWindow` | 私有 |
| 其他 Space 的窗口 AX 元素 | `_AXUIElementCreateWithRemoteToken` | 私有 |
| 窗口层级 / 屏幕上窗口 | `CGWindowListCopyWindowInfo` | 公开 |
| Space 列表 / 窗口所属 Space | `SLSMainConnectionID`、`SLSCopyManagedDisplaySpaces`、`SLSCopyWindowsWithOptionsAndTags`、`SLSCopySpacesForWindows` | 私有（SkyLight） |
| 窗口截图 | ScreenCaptureKit：`SCShareableContent`、`SCScreenshotManager` | 公开（需屏幕录制权限） |
| 批量快速截图（可选加速） | `SLSHWCaptureWindowList` | 私有（SkyLight） |
| 原始触控数据 | `MTDeviceCreateList`、`MTRegisterContactFrameCallback`、`MTDeviceStart` | 私有（MultitouchSupport） |
| 精确聚焦到指定窗口（可选增强） | `_SLPSSetFrontProcessWithOptions`、`SLPSPostEventRecordTo` | 私有（SkyLight） |
| 全局快捷键 | Carbon `RegisterEventHotKey` | 公开 |
| 开机启动 | `SMAppService.mainApp` | 公开 |

已在本机 macOS 27.0.1 上用 `dlsym` 验证：上表列出的私有符号均存在。**符号存在不等于行为正确**，结构体布局、参数语义需在 M0 / M3 阶段实测。

> `CGWindowListCreateImage` 已废弃，在 macOS 15 SDK 中不可用，不再使用。

---

## 3. 总体架构

```
┌────────────────────────────── WindowDeck.app ──────────────────────────────┐
│                                                                            │
│  触发层                     控制层                       展示层            │
│  ┌──────────────┐        ┌──────────────────┐        ┌──────────────────┐ │
│  │GestureService│──┐     │                  │        │ OverlayPanel×屏幕 │ │
│  └──────────────┘  ├───▶ │ OverlayController│ ─────▶ │  ├ DeckView       │ │
│  ┌──────────────┐  │     │  (状态机)        │        │  ├ ExposeView     │ │
│  │HotkeyService │──┘     └───────┬──────────┘        │  └ CardLayer      │ │
│  └──────────────┘                │                   │     └TrafficLights│ │
│                                  │ 读快照 / 执行操作  └──────────────────┘ │
│  数据层                          ▼                                         │
│  ┌──────────────┐   ┌──────────────────┐   ┌────────────────┐             │
│  │ SpaceTracker │──▶│  WindowCatalog   │◀──│ AXObserverHub  │             │
│  └──────────────┘   │ (@MainActor 状态)│   └────────────────┘             │
│                     └───────┬──────────┘                                   │
│  ┌────────────────┐         │          ┌────────────────┐                  │
│  │ThumbnailService│◀────────┴─────────▶│ WindowActions  │                  │
│  └────────────────┘                    └────────────────┘                  │
│                                                                            │
│  基础层：Platform/Private（dlsym 封装）· Accessibility 封装 · Permission     │
│  横切：SettingsStore · CapabilityRegistry · Logger                          │
└────────────────────────────────────────────────────────────────────────────┘
          ▲
          │ 纯逻辑（无 AppKit 依赖）
┌─────────┴──────────── WindowDeckCore (Swift Package) ──────────────────────┐
│  Model · Layout(Deck / Expose) · Gesture(Recognizer) · TitleFormatter ·    │
│  Settings(Codable + 迁移)                                                   │
└────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 模块职责

| 模块 | 职责 |
|---|---|
| `GestureService` | 打开触控设备，接收触控帧，交给 `SwipeRecognizer` 识别，在主线程发出 `.swipeUp` / `.swipeDown` |
| `HotkeyService` | 注册 / 注销用户配置的快捷键（默认无） |
| `OverlayController` | 覆盖层状态机；决定展示哪个视图；协调快照、缩略图、布局、动画；处理键盘与鼠标交互 |
| `WindowCatalog` | 维护全部应用与窗口的内存模型（`AppInfo` / `WindowInfo`），提供不可变快照，记录最近使用顺序（MRU） |
| `AXObserverHub` | 每个应用一个 `AXObserver`，监听窗口创建 / 销毁 / 标题 / 最小化 / 移动 / 缩放 / 聚焦变化 |
| `SpaceTracker` | 维护 Space 列表、当前 Space、窗口所属 Space |
| `ThumbnailService` | 截图、缓存、按需刷新、预热 |
| `WindowActions` | 聚焦、关闭、最小化、全屏 / 缩放、隐藏应用 |
| `PermissionService` | 检测并引导辅助功能、屏幕录制权限 |
| `CapabilityRegistry` | 启动时探测私有符号可用性，产出能力开关，UI 据此降级 |
| `SettingsStore` | 读写配置（`UserDefaults` 中的 JSON），广播变更 |

---

## 4. 数据模型（WindowDeckCore）

```swift
public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: CGWindowID              // 稳定主键
    public let pid: pid_t
    public var title: String               // 原始标题，可能为空
    public var frame: CGRect               // 全局坐标，左上角原点（与 AX 一致）
    public var displayID: CGDirectDisplayID?
    public var spaceIDs: [UInt64]          // 所在 Space；全部 Space 可见的窗口有多个
    public var isMinimized: Bool
    public var isFullscreen: Bool
    public var isOnCurrentSpace: Bool
    public var lastFocusedAt: Date?        // MRU 排序依据
}

public struct AppInfo: Identifiable, Hashable, Sendable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let bundleID: String?
    public var name: String
    public var isHidden: Bool              // Cmd+H 隐藏
    public var windowIDs: [CGWindowID]     // 按 MRU 排序
    public var lastActivatedAt: Date?
}

public struct CatalogSnapshot: Sendable {
    public let apps: [AppInfo]             // 按 MRU 排序
    public let windows: [CGWindowID: WindowInfo]
    public let currentSpaceIDs: Set<UInt64> // 每个显示器各有一个当前 Space
    public let frontmostPID: pid_t?
    public let takenAt: Date
}
```

App 层持有不可序列化的部分（不进入 Core）：

```swift
final class WindowHandle {               // App 层，非 Sendable，仅在其所属应用的 AX 队列上使用
    let windowID: CGWindowID
    let element: AXUIElement
}
```

**坐标系**：AX 和 CG 用的是"主屏左上角为原点、y 向下"，Cocoa（`NSWindow` / `NSScreen`）用的是"主屏左下角为原点、y 向上"。统一在 `CoordinateConverter` 中转换：`cocoaY = primaryScreenHeight - axY - height`。

---

## 5. 窗口发现（WindowCatalog / AXObserverHub）

### 5.1 应用生命周期

- 启动时遍历 `NSWorkspace.shared.runningApplications`，筛选 `activationPolicy == .regular` 的应用；`.accessory` 应用在其拥有标准窗口时也纳入（例如部分菜单栏工具的设置窗口），可在设置中关闭。
- 监听 `NSWorkspace` 通知：`didLaunchApplication`、`didTerminateApplication`、`didActivateApplication`（更新 MRU）、`didHideApplication` / `didUnhideApplication`、`activeSpaceDidChange`、`didWake`。
- 排除自身进程和用户配置的排除列表（`excludedBundleIDs`）。

### 5.2 每个应用的 AX 处理

1. `AXUIElementCreateApplication(pid)`，并设置 `AXUIElementSetMessagingTimeout(element, 0.25)`，防止无响应的应用阻塞调用方。
2. 读取 `kAXWindowsAttribute` 得到当前 Space 的窗口列表（AX 默认只返回当前 Space 中的窗口和已最小化的窗口）。
3. 对每个窗口：
   - `_AXUIElementGetWindow` 得到 `CGWindowID`；拿不到就丢弃该窗口。
   - 读取 `kAXTitleAttribute`、`kAXRoleAttribute`、`kAXSubroleAttribute`、`kAXPositionAttribute`、`kAXSizeAttribute`、`kAXMinimizedAttribute`、`"AXFullScreen"`。
4. 创建 `AXObserver`，注册通知：
   - 应用级：`kAXWindowCreatedNotification`、`kAXFocusedWindowChangedNotification`、`kAXApplicationHiddenNotification`、`kAXApplicationShownNotification`
   - 窗口级：`kAXUIElementDestroyedNotification`、`kAXTitleChangedNotification`、`kAXWindowMiniaturizedNotification`、`kAXWindowDeminiaturizedNotification`、`kAXWindowMovedNotification`、`kAXWindowResizedNotification`
5. 刚启动的应用可能还没准备好 AX（返回 `kAXErrorCannotComplete`），用指数退避重试（0.1s、0.2s、0.4s … 最多 5 次）。

### 5.3 线程模型

- **每个应用一个串行 `DispatchQueue`**（`com.windowdeck.ax.<pid>`），所有针对该应用的 AX 读写都在这里执行；其中一个应用卡死只会影响它自己的队列。
- `AXObserver` 的 run loop source 挂在一个专用后台线程的 RunLoop 上（`AXObserverThread`），收到回调后把事件转到对应应用的队列处理，再把结果合并回 `@MainActor` 的 `WindowCatalog`。
- `WindowCatalog` 合并更新做节流（16ms 合并一批），避免拖动窗口时 `moved` / `resized` 通知刷屏。
- Swift 6 下 `AXUIElement` 不是 `Sendable`：封装为 `WindowHandle`，只在所属队列访问，必要处标注 `@unchecked Sendable` 并写明约束，不在主线程直接调用 AX。

### 5.4 窗口过滤规则

满足全部条件的窗口才视为"用户窗口"：

1. 有 `CGWindowID`。
2. `subrole` ∈ {`AXStandardWindow`, `AXDialog`}，或在"特殊应用白名单"中（部分应用的 subrole 不规范，需要积累规则，规则做成内置表加用户覆盖）。
3. 窗口层级为普通层级（通过 `CGWindowListCopyWindowInfo` 中的 `kCGWindowLayer == 0` 判断）；已最小化 / 其他 Space 的窗口不在列表中时跳过这一条。
4. 尺寸不小于 100×50（排除工具条、浮层）。
5. 排除 Finder 的桌面窗口、自身窗口。
6. 标题为空时不丢弃，展示时退化为"应用名 · 窗口 N"。

### 5.5 其他 Space 的窗口（M4）

AX 不会返回其他 Space 的窗口，补全流程：

1. `SpaceTracker` 通过 `SLSCopyManagedDisplaySpaces(cid)` 拿到每个显示器的 Space 列表和当前 Space。
2. `SLSCopyWindowsWithOptionsAndTags(cid, 0, spaces, options, …)` 拿到所有 Space 的窗口 ID，与 `CGWindowListCopyWindowInfo(.optionAll)` 的 owner pid 对应。
3. 对于"有窗口 ID 但 AX 列表里没有"的窗口，用 `_AXUIElementCreateWithRemoteToken` 构造 AX 元素：令牌为 20 字节，包含 `pid`、保留字段、固定魔数和元素 ID，遍历元素 ID 区间，找到 `_AXUIElementGetWindow` 匹配的元素即可。
   - 这一过程开销较大：只在后台低优先级执行，每个应用设置时间预算（例如 50ms），结果缓存，直到窗口销毁才失效。
   - 令牌格式未公开，需实测确认；失败时这些窗口只展示"标题 + 图标"、不可操作（聚焦可退化为"激活应用"）。
4. 设置项 `showWindowsFromOtherSpaces` 默认开启。

### 5.6 MRU 排序

- 应用顺序：`didActivateApplication` 更新 `lastActivatedAt`。
- 窗口顺序：`kAXFocusedWindowChangedNotification` 更新 `lastFocusedAt`；首次启动时没有历史，用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 的前后顺序（z-order）初始化。

---

## 6. 缩略图（ThumbnailService）

### 6.1 截图路径

| 路径 | 用途 | 说明 |
|---|---|---|
| ScreenCaptureKit（默认） | 单窗口截图 | `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` 拿到 `SCWindow`；`SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage(contentFilter:configuration:)` |
| `SLSHWCaptureWindowList`（可选） | 批量快速截图 | 私有 API，一次截多个窗口；由 `CapabilityRegistry` 探测，设置中"实验性：快速截图"开关控制 |

- `SCShareableContent` 的调用本身较慢（通常几十到上百毫秒，需实测），在后台维护一份 `[CGWindowID: SCWindow]` 缓存，窗口增删时增量刷新。
- `SCStreamConfiguration`：宽高按"窗口尺寸 × 屏幕 backingScaleFactor"计算，最长边上限由画质项决定（省内存 960px / 均衡 1600px / 清晰 2560px）；`showsCursor = false`；`captureResolution = .best`。缩略图图层使用 `minificationFilter = .trilinear`。
- 已最小化的窗口无法截到实时画面：用最小化前最后一次的缓存；没有缓存时显示应用图标占位。
- 其他 Space 的窗口能否被 ScreenCaptureKit 截到需实测；截不到时同样使用缓存。

### 6.2 缓存与刷新策略

- `NSCache<CGWindowID, Thumbnail>`，`Thumbnail { image: CGImage, capturedAt: Date, pixelSize: CGSize }`，总成本上限约 200MB。
- **预热**：窗口失去焦点时（`kAXFocusedWindowChangedNotification`）异步截一次刚失焦的窗口，保证覆盖层打开时缓存基本是新的。
- **打开时**：先用缓存立即渲染；同时按"当前屏幕可见卡片优先"的顺序并发刷新（最大并发 4），刷新完成后在卡片上交叉淡入替换。
- 超过 `staleInterval`（默认 2s）的缓存才会在打开时刷新。
- "仅标题"模式下完全不调用截图，也不预热。

### 6.3 权限

- `CGPreflightScreenCaptureAccess()` 检测，`CGRequestScreenCaptureAccess()` 触发系统授权。
- 授权后通常需要重启应用才生效：引导页提示"授权后点击重新启动"，调用自身重启。
- 自 macOS 15 起系统会周期性（每月）再次确认屏幕录制权限，属于系统行为，无需处理；macOS 27 的具体表现需实测。
- 开发期注意：用固定的签名身份签名 Debug 包，否则每次重新构建 TCC 都会认为是新应用、权限丢失。

---

## 7. 窗口操作（WindowActions）

所有操作都在目标应用的 AX 队列上执行，失败时给出轻提示（卡片抖动 + toast），并写日志。

| 操作 | 实现 | 回退 / 备注 |
|---|---|---|
| 聚焦窗口 | 1）`NSRunningApplication.activate()`；2）对窗口执行 `kAXRaiseAction`；3）设置应用的 `kAXMainWindowAttribute` / `kAXFocusedWindowAttribute` | 增强（可选）：用 `_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo` 精确把某个窗口设为 key window，解决同一应用多窗口时偶尔聚焦错窗口的问题 |
| 关闭（红） | 读取 `kAXCloseButtonAttribute` 并 `AXPress` | 无关闭按钮则禁用红灯。应用弹出"是否保存"时，覆盖层收起并聚焦到该窗口 |
| 收起（黄） | 设置 `kAXMinimizedAttribute = true` | 已最小化的窗口上黄灯变为"恢复" |
| 绿灯 | 默认：切换 `"AXFullScreen"`；可配置为"缩放"：按 `kAXZoomButtonAttribute` | 不支持全屏的窗口回退为缩放 |
| 隐藏应用 | `NSRunningApplication.hide()` | Deck 视图中应用标题栏的菜单项 |
| 退出应用 | `NSRunningApplication.terminate()` | 同上，需二次确认（可配置） |
| 恢复隐藏应用的窗口 | `unhide()` 后聚焦 | |

关闭 / 收起后不关闭覆盖层，卡片做淡出动画，布局重新计算并动画过渡（与系统行为不同，便于连续整理窗口）；是否"操作后自动收起覆盖层"可配置。

---

## 8. 覆盖层（OverlayController / OverlayPanel）

### 8.1 窗口配置

```swift
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu - 1               // 盖住菜单栏与 Dock，低于弹出菜单，保证提示与菜单可见
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true }   // 接收键盘，同时不激活应用
}
```

- 每个显示器一个 `OverlayPanel`，按设置显示"本屏窗口"或"全部窗口集中在主屏"。
- 背景：`NSVisualEffectView`（`.fullScreenUI` 材质，`.behindWindow`）+ 一层可调透明度的暗色遮罩。
- 覆盖层自身窗口在截图 / 窗口枚举中排除。
- **触发前先记录前台应用**：Exposé 视图依赖"当前应用"，必须在 `OverlayPanel` 成为 key 之前读取 `NSWorkspace.shared.frontmostApplication`。

### 8.2 状态机

```
            gesture/hotkey(mode)
  hidden ─────────────────────────▶ presenting(mode) ──动画完成──▶ visible(mode)
    ▲                                                                │
    │                 ┌──────────────────────────────────────────────┤
    │                 │ Esc / 点击空白 / 反向手势 / 同一快捷键 / 聚焦窗口   │
    │                 ▼                                              │
    └──动画完成── dismissing ◀──────────────────────────────────────┘

  visible(deck)   + 三指下滑 → dismissing
  visible(expose) + 三指上滑 → dismissing
  visible(mode A) + mode B 的快捷键 → 直接切换到 visible(mode B)（交叉淡入）
```

presenting / dismissing 期间收到的触发事件会排队，只保留最后一个。

### 8.3 动画

- **出现**：背景 0→1 淡入（180ms）；每张卡片从其窗口的**真实屏幕位置和尺寸**（由 `WindowInfo.frame` 转换得到）动画到布局目标位置（240ms，`easeOut` 弹簧），模拟系统的"飞入"效果。不在当前屏 / 已最小化 / 其他 Space 的窗口从目标位置缩放 0.9→1 加淡入。
- **消失**：反向动画；如果是"聚焦某窗口"触发的，该卡片飞回窗口真实位置，其余淡出。
- 设置中提供"减少动态效果"开关，并遵循系统的 `accessibilityDisplayShouldReduceMotion`。
- 动画全部用 Core Animation（`CABasicAnimation` / `CASpringAnimation`），在主线程提交事务，不在动画期间做同步 AX 调用。

### 8.4 交互

| 输入 | Deck 视图 | Exposé 视图 |
|---|---|---|
| 鼠标悬停卡片 | 高亮，显示红绿灯；悬停牌堆约 300ms 后展开（见 9.1） | 高亮，显示红绿灯 |
| 单击卡片 | 聚焦该窗口并收起覆盖层 | 同左 |
| 单击露出的标题条 | 直接聚焦该窗口 | — |
| 方向键 | 在牌堆间 / 牌堆内移动选中 | 在卡片间移动 |
| `Return` | 聚焦选中窗口 | 同左 |
| `Esc` / 点击空白 | 收起 | 收起 |
| `Cmd+W` / `Cmd+M` | 关闭 / 收起选中窗口 | 同左 |
| `Tab` / `Shift+Tab` | — | 切换到下一个 / 上一个应用的窗口（与系统 App Exposé 一致） |
| 输入字符（可选，M5） | 按标题模糊过滤 | 同左 |

---

## 9. 布局算法（WindowDeckCore/Layout）

布局是纯函数：`(输入模型, 可用区域, 配置) -> [卡片 ID: CGRect]`，便于单测与动画插值。

### 9.1 Deck 视图（三指上滑）

**输入**：按 MRU 排序的应用列表，每个应用有按 MRU 排序的窗口；可用区域 = 屏幕 `visibleFrame` 减去边距。

**第一步：牌堆网格**

- 设应用数为 N，对列数 `c = 1…N` 依次尝试：行数 `r = ceil(N / c)`，单元格宽 `w = (W - gap×(c-1)) / c`，高 `h = (H - gap×(r-1)) / r`。
- 每个牌堆需要的高宽比 = 卡片高宽比（默认 10:16）+ 堆叠露出部分（见下）。选择让"卡片面积"最大的列数。
- 牌堆数量超过 `maxDecksPerScreen`（默认 20）时启用纵向滚动。

**第二步：牌堆内部堆叠**

```
          ┌───────────────────────────┐  ← 第 3 张（最旧）只露出 peek 高度
          │ ● ● ●  标题 3              │
        ┌─┴───────────────────────────┴─┐  ← 第 2 张
        │ ● ● ●  标题 2                  │
      ┌─┴───────────────────────────────┴─┐  ← 第 1 张（最近使用）完整显示
      │ ● ● ●  标题 1                      │
      │                                   │
      │         窗口缩略图                  │
      │                                   │
      └───────────────────────────────────┘
        [图标] 应用名 · 3 个窗口
```

- 最近使用的窗口在最前（最下方），完整显示；更早的窗口依次向上偏移，每层露出 `peek = titleBandHeight + contentPeek`：
  - `titleBandHeight` 由标题字号与行数算出（见第 10 节），保证大字号时标题依然完整可读；
  - `contentPeek` 默认 36pt，可配置 0–120pt，即"露出部分窗口内容"的高度。
- 后层卡片宽度依次收窄 `inset = 8pt × 层数`，形成纵深感；最多显示 `maxStackDepth`（默认 5）层，超出部分在顶部显示 `+N` 标记。
- 牌堆总高度 = `cardHeight + peek × (可见层数 - 1) + 应用标题行高度`，反推 `cardHeight` 以适配单元格。
- 只有一个窗口的应用就是一张卡片；没有窗口的应用默认不显示（可配置为显示一个只有图标的牌堆，点击即激活该应用）。

**第三步：悬停展开（M2）**

- 悬停牌堆超过 300ms，牌堆在原位"扇形 / 纵向"展开为该应用窗口的小网格（复用 Exposé 布局算法，限制在牌堆单元格放大 1.6 倍后的区域内），离开后收拢。
- 展开状态下可直接点击任意窗口或使用红绿灯。

**"仅标题"模式下的 Deck**：每个牌堆变为"应用头部 + 窗口标题列表"的卡片，每行一个窗口（大字号标题 + 红绿灯 + 状态标记：已最小化 / 其他桌面 / 全屏），布局为瀑布流多列。

### 9.2 Exposé 视图（三指下滑）

**输入**：当前应用的窗口（MRU 顺序）、各窗口原始尺寸、可用区域。

**行分配算法（保持宽高比、最大化缩放）**：

1. 对行数 `r = 1…n` 依次尝试：按 MRU 顺序贪心地把窗口分到 r 行，使各行"原始宽度之和"尽量均衡。
2. 每行的缩放 = min(可用宽度 / 行内宽度和, 行可用高度 / 行内最大高度)；整体缩放取所有行的最小值，且不超过 1（不放大超过原尺寸），也不低于 `minScale`。
3. 选择整体缩放最大的 r；每行水平居中，整体垂直居中。
4. 每张卡片顶部预留标题区（高度由标题样式决定，与 Deck 一致：红绿灯在左、标题左对齐），计算时从行高中扣除。

**附加区域**：

- 已最小化的窗口放在底部的"已收起"条带中，使用较小的缩略图。
- 其他 Space 的窗口可选放入单独分组（"其他桌面"），默认与当前桌面的窗口合并展示，并加角标。

> 可选的"保持相对位置"布局（类似系统调度中心，把窗口按真实位置分散排布、避免重叠）放到 M5 评估，MVP 用网格。

---

## 10. 标题展示（TitleFormatter / TitleStyle）

### 10.1 样式配置

```swift
public struct TitleStyle: Codable, Sendable, Equatable {
    public var fontSize: Double = 15        // 范围 11–40
    public var weight: FontWeight = .semibold
    public var maxLines: Int = 2            // 1–3
    public var truncation: Truncation = .middle   // head / middle / tail
    public var showAppNamePrefix: Bool = false    // Exposé 视图中通常不需要
    public var background: TitleBackground = .pill // none / pill / bar
}
```

- 标题区高度 = `ceil(lineHeight(fontSize) × maxLines) + 上下内边距`，参与布局计算（第 9 节），因此大字号不会被裁切，代价是卡片缩略图变小。
- 卡片太窄、标题显示不下时，悬停卡片会弹出完整标题浮层。
- 用 `NSAttributedString` + `CATextLayer`，或在卡片层上叠加 `NSTextField`。需比较两者在大量卡片时的性能，倾向前者。

### 10.2 标题清洗（提升可区分度）

很多应用的标题格式是"文档名 — 项目名 — 应用名"，最有区分度的部分容易被截断。`TitleFormatter` 提供：

1. **去掉应用名后缀**（默认开启）：去掉 ` — AppName`、` - AppName` 一类后缀。
2. **公共前后缀折叠**（默认开启）：同一应用的多个窗口标题有相同的前缀或后缀时，把公共部分弱化显示（灰色、较小字号），突出差异部分。
3. **中间截断**：默认截断中间，保留开头与结尾。
4. 空标题 → `应用名 · 窗口 N`。

以上全部是纯函数，放在 Core 中并有单测。

---

## 11. 红绿灯（TrafficLightsView）

- 位置：卡片左上角，与 macOS 窗口一致（关闭、收起、绿灯从左到右）。
- 显示时机（可配置）：`onHover`（默认）/ `always` / `never`。
- 尺寸随卡片缩放，但设最小可点击区域 16×16pt，最大 22×22pt。
- 每个按钮单独可配置是否显示（`showClose` / `showMinimize` / `showGreen`）；绿灯行为 `greenAction`：`fullscreen`（默认）/ `zoom`。
- 当窗口不支持某个操作时（例如没有关闭按钮），对应按钮置灰、不可点。
- Deck 视图中，露出的后层标题条上也显示一组小号红绿灯，可以不展开牌堆直接关闭 / 收起后层窗口。
- 关闭操作可配置"按住 Option 才执行"或"二次确认"，默认直接执行（与系统一致）。

---

## 12. 手势（GestureService / SwipeRecognizer）

### 12.1 前提：关闭系统手势

系统手势开着时，三指上下滑会被 Dock 处理，第三方无法拦截。处理方式：

1. 启动时与设置页检测手势冲突（读取偏好，键名需实测确认）：
   - `com.apple.AppleMultitouchTrackpad` / `com.apple.driver.AppleBluetoothMultitouch.trackpad`：`TrackpadThreeFingerVertSwipeGesture`（本机当前为 `2`，即三指垂直轻扫由系统使用）
   - `com.apple.dock`：`showMissionControlGestureEnabled`、`showAppExposeGestureEnabled`（本机后者为 `1`）
   - 三指拖移（辅助功能设置）：开启时三指滑动会被当作拖拽，需要提示用户。
2. 检测到冲突时，在菜单栏图标加角标，设置页给出说明，并提供按钮直接打开"系统设置 → 触控板 → 更多手势"（`x-apple.systempreferences:com.apple.Trackpad-Settings.extension`）。
3. **不自动修改系统偏好**（侵入性高、需要重启 Dock、可能不同版本键名不同）。可在 M5 评估"一键关闭系统手势"的可选高级功能，并能一键恢复。

关闭系统手势后，用户仍可用 `Control+↑` / `Control+↓` 或 F3 调出系统自带的调度中心，不影响系统功能。

### 12.2 触控数据接入

- 运行时 `dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport")`，`dlsym` 拿到：
  - `MTDeviceCreateList() -> CFArray`（所有触控设备，包括内置触控板和妙控板）
  - `MTRegisterContactFrameCallback(device, callback)`
  - `MTDeviceStart(device, 0)` / `MTDeviceStop(device)`
  - `MTUnregisterContactFrameCallback(device, callback)`
- 回调签名（社区逆向结果，需在 macOS 27 实测）：
  `(device, touches: UnsafePointer<MTTouch>, count: Int32, timestamp: Double, frame: Int32) -> Int32`
- `MTTouch` 结构体只用到 `identifier`、`state`、`normalized.position (x, y ∈ 0…1)`、`normalized.velocity`；结构体布局按社区版本定义，**M0 原型阶段打印原始数据核对字段偏移**。
- 触点状态：只把 `state == 4（touching）` 计为有效手指。
- 回调在私有线程上执行：回调里只做轻量计算（识别器是值类型、无锁），识别出手势后 `DispatchQueue.main.async` 投递。
- 设备热插拔与睡眠唤醒：监听 `NSWorkspace.didWakeNotification`，用 IOKit 通知（`IOServiceAddMatchingNotification`，匹配触控设备）或每 5s 轻量轮询设备数量，变化时重建设备列表。
- 是否需要额外的 TCC 权限（例如输入监控）**未验证**，M0 实测后补充到权限引导中。

### 12.3 识别算法（纯 Swift，可单测）

```
状态：idle → candidate → tracking → triggered（冷却）→ idle

idle:
  有效手指数 == N（默认 3）并连续 ≥ 2 帧 → candidate，记录 startCentroid、startTime
candidate / tracking:
  每帧计算质心位移 (dx, dy)、速度
  手指数 ≠ N                  → 取消，进入 cooldown（防止与四指手势、捏合误触）
  |dy| ≥ T 且 |dy| ≥ k·|dx|  → 触发 swipeUp / swipeDown（y 轴方向需实测）
  或 |vy| ≥ V 且 |dy| ≥ T/2   → 快速轻扫触发
  经过时间 > 800ms 且未触发    → 取消
triggered / cooldown:
  等待所有手指抬起（有效手指数 == 0）→ idle
```

| 参数 | 默认值 | 可配置 |
|---|---|---|
| 手指数 N | 3 | 3 / 4 |
| 位移阈值 T（归一化） | 0.10 | 灵敏度滑块映射到 0.06–0.18 |
| 方向比 k | 1.8 | 否 |
| 速度阈值 V | 实测后确定 | 否 |
| 最长手势时长 | 800ms | 否 |

- 每次手势最多触发一次，抬起所有手指后才重置。
- 横向三指滑动（切换全屏应用）不受影响：方向比 k 会过滤掉横向位移为主的滑动。
- M5 可选"跟手"模式：把 `dy / T` 作为进度值实时驱动覆盖层的出现动画，松手时根据进度决定完成还是回弹。

---

## 13. 快捷键（HotkeyService）

- 使用 Carbon `RegisterEventHotKey` 注册两个快捷键（`deck` / `expose`），配置保存在 `AppSettings.hotkeys` 中，**默认为空**，即默认无快捷键。
- 设置页使用自绘的 `HotkeyRecorder` 录制（`NSEvent` 本地监听，Esc 取消、Delete 清除；无修饰键时只允许功能键）；录制期间暂停已注册的快捷键。
- 不使用 `KeyboardShortcuts`：SwiftPM 资源 bundle 放在手工组装的 `.app` 根目录会破坏签名，且其 `#Preview` 宏在 CLT 下无法编译；功能本身很小，自行实现即可。
- 行为：覆盖层隐藏时按下 → 打开对应视图；对应视图已显示时按下 → 收起；另一视图显示时按下 → 切换。
- 冲突检测：注册失败（被其他应用占用）时在录制控件旁提示。

---

## 14. 设置（SettingsStore）

### 14.1 配置模型

```swift
public struct AppSettings: Codable, Sendable, Equatable {
    public var schemaVersion = 1

    // 触发
    public var gesture = GestureSettings()          // enabled=true, fingers=3, sensitivity=0.5, followFinger=false
    public var hotkeys = HotkeySettings()           // deck / expose，默认 nil

    // 展示
    public var showThumbnails = true                // false = 仅标题模式（F5）
    public var thumbnailQuality: Quality = .balanced
    public var titleStyle = TitleStyle()
    public var titleCleanup = TitleCleanup()        // stripAppSuffix=true, foldCommonAffix=true
    public var deck = DeckSettings()                // contentPeek=36, maxStackDepth=5, showAppsWithoutWindows=false
    public var expose = ExposeSettings()            // showMinimizedStrip=true, groupOtherSpaces=false
    public var trafficLights = TrafficLightSettings() // visibility=.onHover, showClose/Minimize/Green=true, greenAction=.fullscreen
    public var appearance = AppearanceSettings()    // dimOpacity=0.35, reduceMotion=.system

    // 过滤
    public var excludedBundleIDs: [String] = []
    public var showMinimized = true
    public var showHiddenApps = true
    public var showWindowsFromOtherSpaces = true
    public var includeAccessoryApps = true
    public var multiDisplay: MultiDisplayMode = .perScreen   // perScreen / allOnMouseScreen

    // 行为
    public var dismissAfterAction = false
    public var launchAtLogin = false
    public var preciseFocus = true
    public var hasCompletedOnboarding = false
}
```

- 以 JSON 形式存到 `UserDefaults`（键 `settings.v1`）；所有字段有默认值，解码时容忍缺失字段，便于后续升级；`schemaVersion` 用于迁移。
- 支持导入 / 导出 JSON 文件。
- `SettingsStore` 是 `@MainActor @Observable`，SwiftUI 设置页直接绑定，变更后通知各服务（例如关闭缩略图时 `ThumbnailService` 停止预热并清空缓存）。

### 14.2 设置界面分页

1. **通用**：开机启动、手势开关与灵敏度、手指数、快捷键录制、手势冲突状态。
2. **外观**：是否显示窗口内容、画质、标题样式（带实时预览）、遮罩透明度、动画。
3. **牌堆（Deck）**：露出内容高度、最大堆叠层数、是否显示无窗口的应用。
4. **当前应用（Exposé）**：已收起条带、其他桌面分组。
5. **红绿灯**：显示时机、各按钮开关、绿灯行为、关闭确认。
6. **过滤**：排除应用（从运行中应用中选择）、最小化 / 隐藏 / 其他桌面窗口开关、多显示器模式。
7. **权限与诊断**：权限状态、能力开关状态（`CapabilityRegistry`）、导出诊断日志。

---

## 15. 权限与首次启动

| 权限 | 是否必需 | 检测 | 申请 / 引导 |
|---|---|---|---|
| 辅助功能 | 必需 | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`；打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| 屏幕录制 | 显示缩略图时需要 | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()`；打开 `…?Privacy_ScreenCapture`；授权后提示重启 |
| 输入监控 | 待确认 | — | M0 实测后决定 |

首次启动流程：欢迎页 → 辅助功能授权（轮询状态，每 1s 一次，授权后自动进入下一步）→ 屏幕录制授权（可跳过，跳过后进入仅标题模式）→ 手势冲突检测与说明 → 完成，常驻菜单栏。

菜单栏菜单：显示牌堆 / 显示当前应用窗口 / 暂停手势 / 设置… / 权限状态 / 退出。

---

## 16. 私有 API 封装与降级

### 16.1 封装方式

```swift
enum PrivateSymbols {
    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func resolve<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}

enum SkyLight {
    typealias MainConnectionID = @convention(c) () -> Int32
    static let mainConnectionID = PrivateSymbols.resolve(PrivateSymbols.skyLight,
                                                         "SLSMainConnectionID",
                                                         as: MainConnectionID.self)
}
```

- 不在编译期链接私有框架，避免缺失符号时启动崩溃。
- 所有私有 API 的调用集中在 `Platform/Private/` 目录，业务代码只依赖协议（例如 `SpaceProviding`、`TouchDeviceProviding`），方便替换和打桩测试。

### 16.2 能力与降级矩阵

| 能力 | 依赖 | 不可用时的降级 |
|---|---|---|
| `windowID` | `_AXUIElementGetWindow` | 用标题 + frame 与 `CGWindowListCopyWindowInfo` 做模糊匹配；匹配不上的窗口不展示缩略图 |
| `spaces` | SkyLight Space 相关 API | 只展示当前 Space 的窗口 |
| `otherSpaceAX` | `_AXUIElementCreateWithRemoteToken` | 其他 Space 的窗口只读展示，点击 = 激活应用 |
| `gesture` | MultitouchSupport | 关闭手势，提示用户改用快捷键 |
| `fastCapture` | `SLSHWCaptureWindowList` | 使用 ScreenCaptureKit |
| `preciseFocus` | `_SLPSSetFrontProcessWithOptions` 等 | 使用 `activate` + `AXRaise` |

`CapabilityRegistry` 在启动时探测并做一次轻量自检（例如调用 `SLSMainConnectionID()` 检查返回值合理），结果显示在"权限与诊断"页。

---

## 17. 性能目标

| 指标 | 目标 |
|---|---|
| 手势 / 快捷键触发 → 覆盖层第一帧 | ≤ 120ms（缓存命中时） |
| 缩略图全部刷新完成（30 个窗口） | ≤ 600ms（需实测） |
| 覆盖层动画帧率 | 60fps（ProMotion 屏 120fps） |
| 后台常驻 CPU | 空闲时 < 1% |
| 内存 | 常驻 < 150MB，缩略图缓存上限 200MB |

手段：事件驱动维护目录（不轮询）；打开时只读快照；缩略图按需降采样；卡片用 `CALayer` 复用；布局计算放在 Core 中并可在后台线程执行；节流合并 AX 事件。

---

## 18. 边界情况清单

- 无响应的应用：AX 超时，跳过该应用的更新，保留旧数据并在卡片上加"未响应"角标。
- 空标题、超长标题、包含换行或 emoji 的标题。
- 全屏应用（独占一个 Space）：显示"全屏"角标，聚焦时切换到对应 Space。
- 隐藏的应用（Cmd+H）：卡片半透明并加"已隐藏"角标，点击时先 `unhide` 再聚焦。
- 已最小化的窗口：缓存图或图标，黄灯变"恢复"。
- 附着的 sheet / 对话框：作为父窗口的一部分处理，不单独成卡。
- 画中画、浮动面板、工具窗口：按过滤规则排除。
- 多显示器、显示器热插拔（`NSApplication.didChangeScreenParametersNotification` 时重建面板）、不同缩放比例。
- 台前调度（Stage Manager）开启时窗口的 frame 与可见性，需实测。
- 锁屏、屏幕保护程序、系统调度中心正在显示时：不响应触发。
- 输入法、安全输入状态下的快捷键行为。
- 关闭窗口时应用弹出"是否保存"：覆盖层收起并聚焦该窗口。
- 自身覆盖层不能出现在列表与截图中。

---

## 19. 工程结构

```
WindowDeck/
├── Package.swift                     # App 可执行目标，依赖本地包 WindowDeckCore
├── Support/
│   ├── Info.plist                    # LSUIElement = YES
│   └── WindowDeck.entitlements       # Hardened Runtime，无 Sandbox
├── scripts/
│   ├── build-app.sh                  # 构建并组装 build/WindowDeck.app、签名
│   └── test-core.sh                  # 运行 WindowDeckCore 单测
├── Sources/WindowDeck/
│   ├── App/                          # main.swift, AppDelegate, MenuBarController, DevTools（自检 / 离屏预览）
│   ├── Platform/
│   │   ├── Private/                  # PrivateSymbols, SkyLight, Multitouch, AXPrivate
│   │   ├── Accessibility/            # AX 封装、AXObserverThread、AppTracker（每应用一个 AX 队列）
│   │   ├── Capture/                  # ThumbnailService
│   │   └── CoordinateConverter.swift
│   ├── Services/                     # WindowCatalog（含 OtherSpaceScanner）, GestureService（含冲突检测）,
│   │                                 # HotkeyService, PermissionService, CapabilityRegistry, SettingsStore, Log
│   ├── Overlay/                      # OverlayController + OverlayPanel, OverlayContentView, CardView,
│   │                                 # TrafficLightsView, TitleRenderer, SupportViews
│   ├── Settings/                     # SwiftUI 设置页、HotkeyRecorder
│   └── Onboarding/                   # 首次启动与权限引导
├── Packages/WindowDeckCore/
│   ├── Sources/WindowDeckCore/
│   │   ├── Model/                    # WindowInfo, AppInfo, CatalogSnapshot, MRUOrdering
│   │   ├── Layout/                   # DeckLayout, ExposeLayout, TitleListLayout, SpatialNavigation
│   │   ├── Gesture/                  # SwipeRecognizer, TouchFrame
│   │   ├── Title/                    # TitleFormatter, TitleStyle
│   │   └── Settings/                 # AppSettings, SettingsCodec
│   └── Tests/WindowDeckCoreTests/    # Swift Testing
└── docs/
    └── technical-design.md
```

模块与第 3.1 节的对应：`AXObserverHub` 的职责由 `AXObserverThread` + `AppTracker` 承担；`SpaceTracker` 的职责由 `SkyLight` 封装 + `OtherSpaceScanner` 承担；`WindowActions` 由 `AppTracker.perform` + `WindowCatalog.perform` 承担；`DeckView` / `ExposeView` 合并为 `OverlayContentView` 的两种模式。

## 20. 测试策略

### 20.1 单元测试（`swift test`，在 WindowDeckCore 中）

- `DeckLayout`：1 / 2 / 7 / 20 / 50 个应用；单窗口与多窗口；超过 `maxStackDepth`；大字号标题时卡片高度反推正确；所有卡片都在可用区域内且互不重叠。
- `ExposeLayout`：不同宽高比混排；极端宽 / 高窗口；缩放不超过 1；结果确定（相同输入得到相同输出）。
- `SwipeRecognizer`：用合成的触控帧序列测试：标准上滑 / 下滑、横向滑动不触发、四指不触发、中途加减手指取消、慢速超时、一次手势只触发一次。
- `TitleFormatter`：去后缀、公共前后缀折叠、中间截断、空标题。
- `AppSettings`：缺字段解码、旧版本迁移、往返编码。

### 20.2 集成 / 手工测试矩阵

| 维度 | 覆盖 |
|---|---|
| 应用类型 | Finder、Safari、Chrome、VS Code（Electron）、Terminal、Xcode、Office、JetBrains IDE（Java）、预览、微信 / 飞书类应用 |
| 窗口状态 | 普通、最小化、隐藏、全屏、其他 Space、其他显示器、sheet |
| 环境 | 单屏 / 双屏 / 不同缩放、台前调度开关、深色 / 浅色、减少动态效果 |
| 规模 | 50+ 窗口、20+ 应用 |
| 异常 | 应用无响应、应用在覆盖层显示期间退出、权限中途被撤销、睡眠唤醒、外接触控板插拔 |

### 20.3 质量工具

- `swift-format` 或 SwiftLint（二选一，M0 确定）。
- `os.Logger` 分类日志（`gesture`、`catalog`、`capture`、`overlay`），诊断页可导出；日志中不记录窗口内容，标题记录做可选脱敏。
- 用 Instruments（Time Profiler、Allocations、Core Animation）验证第 17 节的性能目标。

---

## 21. 里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **M0 原型验证** | 工程骨架、菜单栏、权限引导；三个技术原型：①MultitouchSupport 回调打印原始触点 ②ScreenCaptureKit 截取任意窗口 ③`_AXUIElementGetWindow` 与 SkyLight Space 枚举 | 在 macOS 27 上三项原型都能跑通，并记录结构体布局 / 参数结论；确定是否需要输入监控权限 |
| **M1 最小可用版本** | `WindowCatalog`（当前 Space）、快捷键触发、仅标题模式的 Deck / Exposé、红绿灯、聚焦 | 用快捷键能打开两个视图，能聚焦 / 关闭 / 收起 / 全屏窗口；标题字号可调 |
| **M2 缩略图与视觉** | `ThumbnailService`、堆叠露出内容、飞入动画、悬停展开、标题清洗、设置页外观项 | 30 个窗口时打开 ≤ 120ms（缓存命中），动画流畅 |
| **M3 手势** | `GestureService`、`SwipeRecognizer`、冲突检测与引导、睡眠唤醒 / 热插拔 | 关闭系统手势后，三指上 / 下滑稳定触发，误触发率低（主观测试 + 单测） |
| **M4 完整窗口覆盖** | 其他 Space、已最小化、隐藏应用、多显示器、精确聚焦 | 第 18 节边界情况全部有明确行为 |
| **M5 打磨与发布** | 性能优化、跟手动画、搜索过滤、可选"保持相对位置"布局、签名公证、可选自动更新 | 公证通过，可在另一台 Mac 上安装运行 |

---

## 22. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| 私有 API 在系统升级后变化或被移除 | 手势 / 跨 Space / 精确聚焦失效 | 运行时解析 + `CapabilityRegistry` 降级；快捷键始终可用；每个 macOS beta 发布时回归一次 |
| `MTTouch` 结构体布局与社区版本不一致 | 手势识别错误 | M0 打印原始数据核对；结构体按版本选择布局 |
| 屏幕录制权限周期性重新确认 | 体验打扰 | 属于系统行为；引导页说明；拒绝后自动退回仅标题模式 |
| 部分应用 AX 支持差（subrole 不规范、标题为空、响应慢） | 窗口缺失或卡顿 | 特殊应用规则表、超时、按应用隔离队列 |
| ScreenCaptureKit 截图慢 / 截不到其他 Space 的窗口 | 缩略图延迟或缺失 | 预热缓存、可见区域优先、可选私有快速截图路径 |
| 覆盖层层级不足（被全屏应用 / 系统 UI 遮挡） | 显示异常 | 实测调整 `level` 与 `collectionBehavior` |
| 用户未关闭系统手势 | 两套效果同时触发 | 冲突检测、角标提示、一键打开设置 |

---

## 23. 待确认问题

1. **绿灯行为**：需求中的"全部"按"全屏"处理（默认全屏，可配置为缩放）。如果原意是"关闭该应用全部窗口"或"收起全部"，需要调整第 11 节的设计。
2. **多显示器**：默认"每块屏幕只显示本屏窗口"（与系统一致），还是"全部集中到主屏"？
3. **Deck 视图是否包含没有窗口的应用**（例如只剩菜单栏的应用）？默认不包含。
4. **最低系统版本**：14.0 是否可以接受，还是只需支持当前的 macOS 27？
5. **分发范围**：仅自用（可暂不公证），还是计划公开分发？
6. **跟手动画**（覆盖层随手指实时出现）的优先级，目前放在 M5。

---

## 24. 实现状态与调整（v0.2）

### 24.1 已实现

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 工程骨架、菜单栏、权限引导、私有能力探测（`--self-test`） | 已实现；macOS 27.0.1 上 5 项私有能力均可解析 |
| M1 | `WindowCatalog`、快捷键、仅标题模式、红绿灯、聚焦、标题字号 | 已实现 |
| M2 | 缩略图（ScreenCaptureKit + 缓存 + 预热）、堆叠露出内容、飞入动画、悬停展开、标题清洗、外观设置（含实时预览） | 已实现 |
| M3 | `GestureService`、`SwipeRecognizer`、冲突检测与引导、睡眠唤醒 / 热插拔 | 已实现，**真实触控数据未在设备上验证** |
| M4 | 其他桌面窗口（CGWindowList + SkyLight 过滤 + 远程 AX 令牌）、已收起、隐藏应用、多显示器、精确聚焦 | 已实现，**未在真实多桌面 / 多显示器环境验证** |
| M5 | 搜索过滤、跟手动画、"保持相对位置"布局、公证、自动更新 | 未做 |

### 24.2 与原方案的差异

1. **工程形态**：纯 SwiftPM + 打包脚本，不生成 `.xcodeproj`（本机无 xcodegen，手写 pbxproj 易错）。
2. **快捷键**：不引入 `KeyboardShortcuts`，见第 13 节。
3. **覆盖层层级**：`popUpMenu - 1` 而非 `.screenSaver`，见第 8.1 节。
4. **多显示器**：`allOnMain` 改为 `allOnMouseScreen`（集中到鼠标所在屏幕，比固定主屏更符合使用习惯）。
5. **AX 超时**：除应用元素外，还设置了进程级默认超时 0.5s（窗口元素不继承应用元素的超时）。
6. **窗口过滤**：subrole 为空或 `AXUnknown` 但有关闭 / 最小化按钮的窗口也视为用户窗口，作为"特殊应用规则表"的通用兜底。
7. **其他桌面窗口**：通过 `CGWindowListCopyWindowInfo(.optionAll)` 找候选，用 `SLSCopySpacesForWindows` 过滤掉不受 Space 管理的窗口；远程令牌解析失败且有标题的窗口只读展示（点击激活应用）。完整扫描仍找不到的窗口会被记住，不重复扫描。
8. **关闭后弹出表单**：关闭 0.5s 后若窗口仍在且挂着 `AXSheet`，收起覆盖层并聚焦该窗口。

### 24.3 验证情况

- `scripts/test-core.sh`：47 个单元测试通过（布局、手势识别、标题清洗、配置解码与迁移、MRU 排序、方向键导航）。
- `WindowDeck --render-preview <dir>`：用合成数据离屏渲染 Deck / Exposé / 仅标题 / 大字号 / 整条标题背景，人工检查布局。
- `WindowDeck --self-test`：本机私有符号全部可用；触控设备 1 个；检测到系统手势冲突（`TrackpadThreeFingerVertSwipeGesture=2`）。
- **未验证**（需要授予权限后人工测试）：真实窗口枚举与操作、缩略图截取速度、三指手势触发、其他桌面窗口解析、精确聚焦、飞入 / 展开动画的实际观感、多显示器。

---

## 25. Chrome 标签页（v0.3，实验性）

当前应用是 Google Chrome（含 Beta / Dev / Canary）时，三指下滑的 Exposé 视图默认改为**标签页视图**，每行一个标签页（当前标签加粗并带强调色标记、右侧域名），点击切换，悬停 × / ⌘W 关闭，按 T 在"窗口 / 标签页"之间切换，按 G 切换分组方式（写入设置）：

- **按域名（默认）**：`BrowserTabGrouper`（Core）按主机名的最后三段分组（`xx.xx.xx`：mail.google.com 与 translate.google.com 分开；a.b.example.com → b.example.com；去掉开头的 `www.`；非网页按 scheme，如 `chrome://`）。标签多的组在前；只有一个标签页的域名不少于 2 个时合并为"其他网站"放最后；有多个窗口时行尾注明"窗口 N"。
- **按窗口**：每个 Chrome 窗口一组（窗口编号 · 标签数 · 无痕 / 已收起 / 其他桌面角标），点击头部切换到该窗口的当前标签页。

后台标签页**不显示缩略图**：浏览器没有接口截取后台标签页（扩展的 `captureVisibleTab` 也只能截当前标签），"标签页显示时截图并缓存"的方案结果不可靠，已放弃。

| 模块 | 说明 |
|---|---|
| `ChromeScripting`（Platform/AppleEvents） | 直接用 `NSAppleEventDescriptor` 拼装对象说明符并 `sendEvent(.waitForReply, .neverInteract, timeout 1.5s)`。不用 `NSAppleScript`（要求主线程）。四字符码取自 Chrome 的 `scripting.sdef`：`cwin` / `CrTb` / `ID  ` / `pnam` / `URL ` / `pbnd` / `mode` / `acTI` / `pmnd` / `pidx` |
| `BrowserTabService` | 后台串行队列；先 `AEDeterminePermissionToAutomateTarget(ask: false)` 判断权限，再按属性批量读取（`get <prop> of every tab of every window`，每个属性一次往返）；每个 pid 缓存最近结果，打开视图先显示缓存再刷新；刷新失败保留旧结果 |
| `BrowserTabMatcher`（Core） | 脚本窗口与系统窗口没有共同 id：先按位置尺寸（误差 ≤ 4pt，标题相同优先）匹配，再按唯一标题匹配。Chrome 的 AX 标题是"标签标题 - [属于“分组”群组 - ]Google Chrome"，脚本里只有标签标题，按"相等或以 `标题 + " - "` 开头"比较（本机实测）。匹配上的窗口切换后用现有的精确聚焦；匹配不上时用脚本 `set index to 1` + 激活应用 |
| `BrowserTabsView`（Overlay） | 复用"仅标题"模式的瀑布流布局（组 = 浏览器窗口，行 = 标签页） |

**切换流程**：收起覆盖层 → 按标签 id 重新定位下标（读取之后标签可能被拖动 / 关闭）→ `set active tab index` → 聚焦对应系统窗口。

**权限**：Hardened Runtime 下需要 `com.apple.security.automation.apple-events` entitlement 与 `NSAppleEventsUsageDescription`。首次显示"授权"按钮，点击后收起覆盖层再发起系统授权（避免授权框被覆盖层挡住）；被拒绝时按钮改为打开 系统设置 → 隐私与安全性 → 自动化。覆盖层显示期间的 Apple Event 一律 `neverInteract`，不会意外弹窗。

**设置**：当前应用 → 浏览器标签页（页面最上方）：`expose.showBrowserTabs`（"启用 Chrome 标签页"，默认开）、`expose.tabGrouping`（按域名 / 按窗口，默认按域名）、`expose.includeIncognitoTabs`（默认关）。

**实测（本机 Chrome，1 窗口 33 标签）**：完整读取约 150ms（9 次往返，每次约 17ms）；切换（重新定位 + 设置）约 32ms。

**限制 / 后续**：后台标签页没有缩略图，也没有 favicon（可考虑读取 Chrome 本地的 Favicons 数据库）；读取耗时随属性数线性增长，可考虑在 Chrome 激活时预取；Edge / Brave 等 Chromium 浏览器字典基本一致但未验证；标签数很多时可加输入过滤。
