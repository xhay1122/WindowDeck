import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WindowDeckCore

enum AppTrackerEvent: Sendable {
    /// 应用的完整窗口列表（当前 Space + 已解析到的其他 Space 窗口）。
    case windows(pid: pid_t, windows: [WindowInfo])
    /// 应用内聚焦窗口变化。
    case focused(pid: pid_t, windowID: CGWindowID)
    /// AX 调用超时：保留旧数据，标记"未响应"。
    case unresponsive(pid: pid_t, Bool)
}

enum WindowAction: Sendable {
    case focus(precise: Bool)
    case close
    case toggleMinimize
    case green(GreenAction)
}

/// 单个应用的 AX 状态与操作。所有可变状态只在 `queue` 上访问，因此标记为 @unchecked Sendable。
final class AppTracker: @unchecked Sendable {
    let pid: pid_t
    let queue: DispatchQueue

    private let appElement: AXUIElement
    private let onEvent: @Sendable (AppTrackerEvent) -> Void
    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    /// 观察者回调的 refcon 持有自身，停止后延迟释放，避免回调期间被释放。
    private var retainedSelf: Unmanaged<AppTracker>?

    private var windowElements: [CGWindowID: AXUIElement] = [:]
    private var remoteElements: [CGWindowID: AXUIElement] = [:]
    private var observedWindows: Set<CGWindowID> = []
    private var unresolvableRemote: Set<CGWindowID> = []
    private var refreshScheduled = false
    private var hasSucceededOnce = false
    private var isUnresponsive = false
    private var stopped = false

    static let messagingTimeout: Float = 0.25
    static let minimumWindowSize = CGSize(width: 100, height: 50)
    static let remoteElementScanLimit: UInt64 = 2000

    init(pid: pid_t, onEvent: @escaping @Sendable (AppTrackerEvent) -> Void) {
        self.pid = pid
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "com.windowdeck.ax.\(pid)", qos: .userInitiated)
        self.appElement = AXUIElementCreateApplication(pid)
        AX.setTimeout(appElement, seconds: Self.messagingTimeout)
    }

    // MARK: 生命周期

    func start() {
        queue.async { self.startOnQueue(attempt: 0) }
    }

    func stop() {
        queue.async {
            self.stopped = true
            if let source = self.observerSource {
                AXObserverThread.shared.remove(source)
            }
            self.observer = nil
            self.observerSource = nil
            self.windowElements.removeAll()
            self.remoteElements.removeAll()
            if let retained = self.retainedSelf {
                self.retainedSelf = nil
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { retained.release() }
            }
        }
    }

    private func startOnQueue(attempt: Int) {
        guard !stopped else { return }
        if observer == nil {
            setUpObserver()
        }
        let ok = refreshNow()
        // 刚启动的应用 AX 可能还没就绪：指数退避重试。
        if !ok, attempt < 5 {
            let delay = 0.1 * pow(2, Double(attempt))
            queue.asyncAfter(deadline: .now() + delay) { self.startOnQueue(attempt: attempt + 1) }
        }
    }

    private func setUpObserver() {
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else { return }
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        let refcon = retained.toOpaque()
        let notifications = [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ]
        for name in notifications {
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        let source = AXObserverGetRunLoopSource(created)
        AXObserverThread.shared.add(source)
        observer = created
        observerSource = source
    }

    private func observe(window element: AXUIElement, id: CGWindowID) {
        guard let observer, let refcon = retainedSelf?.toOpaque(), !observedWindows.contains(id) else { return }
        let notifications = [
            kAXUIElementDestroyedNotification,
            kAXTitleChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]
        for name in notifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        observedWindows.insert(id)
    }

    // MARK: 事件

    /// 在观察者线程上调用，只做转发。
    fileprivate func handle(notification: String, element: AXRef) {
        queue.async {
            guard !self.stopped else { return }
            switch notification {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                if let id = AXPrivate.windowID(of: element.element) {
                    self.onEvent(.focused(pid: self.pid, windowID: id))
                }
                self.scheduleRefresh(after: 0.05)
            case kAXWindowMovedNotification, kAXWindowResizedNotification:
                self.scheduleRefresh(after: 0.12)
            case kAXUIElementDestroyedNotification:
                self.scheduleRefresh(after: 0.03)
            default:
                self.scheduleRefresh(after: 0.05)
            }
        }
    }

    /// 合并短时间内的多次刷新请求。
    func scheduleRefresh(after delay: TimeInterval = 0.05) {
        queue.async {
            guard !self.refreshScheduled, !self.stopped else { return }
            self.refreshScheduled = true
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.refreshScheduled = false
                self.refreshNow()
            }
        }
    }

    /// 读取当前聚焦窗口并上报（应用被激活时调用）。
    func reportFocusedWindow() {
        queue.async {
            guard !self.stopped,
                  let window = AX.element(self.appElement, kAXFocusedWindowAttribute),
                  let id = AXPrivate.windowID(of: window) else { return }
            self.onEvent(.focused(pid: self.pid, windowID: id))
        }
    }

    // MARK: 读取

    /// 重新读取窗口列表。返回 false 表示 AX 尚未就绪或超时。
    @discardableResult
    private func refreshNow() -> Bool {
        guard !stopped else { return false }
        let (elements, error) = AX.elements(appElement, kAXWindowsAttribute)
        if error != .success, error != .noValue {
            if error == .cannotComplete, hasSucceededOnce, !isUnresponsive {
                isUnresponsive = true
                onEvent(.unresponsive(pid: pid, true))
            }
            return false
        }
        hasSucceededOnce = true
        if isUnresponsive {
            isUnresponsive = false
            onEvent(.unresponsive(pid: pid, false))
        }

        var infos: [WindowInfo] = []
        var current: [CGWindowID: AXUIElement] = [:]
        for element in elements {
            guard let id = AXPrivate.windowID(of: element),
                  let info = readWindow(element, id: id, onCurrentSpace: true) else { continue }
            current[id] = element
            infos.append(info)
            observe(window: element, id: id)
        }
        for (id, element) in remoteElements {
            if current[id] != nil {
                remoteElements[id] = nil
                continue
            }
            if let info = readWindow(element, id: id, onCurrentSpace: false) {
                infos.append(info)
                observe(window: element, id: id)
            } else {
                remoteElements[id] = nil
            }
        }
        observedWindows.formIntersection(Set(current.keys).union(remoteElements.keys))
        windowElements = current
        onEvent(.windows(pid: pid, windows: infos))
        return true
    }

    private func readWindow(_ element: AXUIElement, id: CGWindowID, onCurrentSpace: Bool) -> WindowInfo? {
        let role = AX.string(element, kAXRoleAttribute)
        guard role == nil || role == kAXWindowRole else { return nil }
        guard let frame = AX.frame(element) else { return nil }
        guard frame.width >= Self.minimumWindowSize.width, frame.height >= Self.minimumWindowSize.height else { return nil }

        let subrole = AX.string(element, kAXSubroleAttribute)
        let hasClose = AX.buttonEnabled(element, kAXCloseButtonAttribute)
        let hasMinimize = AX.element(element, kAXMinimizeButtonAttribute) != nil
        let isStandard = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        // subrole 不规范的应用：有关闭或最小化按钮的窗口也视为用户窗口。
        guard isStandard || ((subrole == nil || subrole == kAXUnknownSubrole) && (hasClose || hasMinimize)) else { return nil }

        var capabilities: WindowCapabilities = [.focus]
        if hasClose { capabilities.insert(.close) }
        if AX.isSettable(element, kAXMinimizedAttribute) { capabilities.insert(.minimize) }
        if AX.isSettable(element, AX.fullScreenAttribute) { capabilities.insert(.fullscreen) }
        if AX.buttonEnabled(element, kAXZoomButtonAttribute) { capabilities.insert(.zoom) }

        return WindowInfo(
            id: id,
            pid: pid,
            title: AX.string(element, kAXTitleAttribute) ?? "",
            frame: frame,
            isMinimized: AX.bool(element, kAXMinimizedAttribute) ?? false,
            isFullscreen: AX.bool(element, AX.fullScreenAttribute) ?? false,
            isOnCurrentSpace: onCurrentSpace,
            capabilities: capabilities
        )
    }

    // MARK: 其他 Space

    /// 用远程令牌遍历元素 ID，为其他 Space 上的窗口找到 AX 元素。返回未能解析的窗口 ID。
    func resolveRemoteWindows(_ candidates: Set<CGWindowID>, budget: TimeInterval, completion: @escaping @Sendable (Set<CGWindowID>) -> Void) {
        queue.async {
            let unresolved = candidates.subtracting(self.windowElements.keys).subtracting(self.remoteElements.keys)
            // 完整扫描过仍找不到的窗口不再重复扫描。
            var missing = unresolved.subtracting(self.unresolvableRemote)
            guard !self.stopped, !missing.isEmpty, AXPrivate.createWithRemoteTokenFn != nil else {
                completion(unresolved)
                return
            }
            let deadline = Date().addingTimeInterval(budget)
            var elementID: UInt64 = 0
            while !missing.isEmpty, elementID < Self.remoteElementScanLimit, Date() < deadline {
                defer { elementID += 1 }
                guard let element = AXPrivate.element(pid: self.pid, elementID: elementID) else { continue }
                AX.setTimeout(element, seconds: 0.05)
                guard AX.string(element, kAXRoleAttribute) == kAXWindowRole,
                      let id = AXPrivate.windowID(of: element),
                      missing.contains(id) else { continue }
                AX.setTimeout(element, seconds: Self.messagingTimeout)
                self.remoteElements[id] = element
                missing.remove(id)
            }
            if elementID >= Self.remoteElementScanLimit {
                self.unresolvableRemote.formUnion(missing)
            }
            if self.remoteElements.keys.contains(where: unresolved.contains) {
                self.refreshNow()
            }
            completion(unresolved.subtracting(self.remoteElements.keys))
        }
    }

    // MARK: 操作

    func perform(_ action: WindowAction, windowID: CGWindowID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard let element = self.windowElements[windowID] ?? self.remoteElements[windowID] else {
                completion(false)
                return
            }
            let ok: Bool
            switch action {
            case let .focus(precise):
                ok = self.focus(element, windowID: windowID, precise: precise)
            case .close:
                if let button = AX.element(element, kAXCloseButtonAttribute) {
                    ok = AX.perform(button, kAXPressAction) == .success
                } else {
                    ok = false
                }
            case .toggleMinimize:
                let minimized = AX.bool(element, kAXMinimizedAttribute) ?? false
                ok = AX.set(element, kAXMinimizedAttribute, AX.cfBool(!minimized)) == .success
            case let .green(mode):
                ok = self.green(element, mode: mode)
            }
            self.scheduleRefresh(after: 0.1)
            completion(ok)
        }
    }

    /// 窗口上是否挂着表单（例如关闭时的"是否保存"）。
    func hasSheet(windowID: CGWindowID, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard let element = self.windowElements[windowID] ?? self.remoteElements[windowID] else {
                completion(false)
                return
            }
            let children = AX.elements(element, kAXChildrenAttribute).elements
            completion(children.contains { AX.string($0, kAXRoleAttribute) == kAXSheetRole })
        }
    }

    private func focus(_ element: AXUIElement, windowID: CGWindowID, precise: Bool) -> Bool {
        if AX.bool(element, kAXMinimizedAttribute) == true {
            AX.set(element, kAXMinimizedAttribute, AX.cfBool(false))
        }
        var activated = false
        if precise, SkyLight.supportsPreciseFocus {
            activated = SkyLight.focus(windowID: windowID, pid: pid)
        }
        if !activated {
            // 公开路径：通过 AX 把应用设为前台，不受"协作式激活"限制。
            activated = AX.set(appElement, kAXFrontmostAttribute, AX.cfBool(true)) == .success
        }
        let raised = AX.perform(element, kAXRaiseAction) == .success
        AX.set(element, kAXMainAttribute, AX.cfBool(true))
        if !activated {
            let pid = self.pid
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
        return activated || raised
    }

    private func green(_ element: AXUIElement, mode: GreenAction) -> Bool {
        if mode == .fullscreen, AX.isSettable(element, AX.fullScreenAttribute) {
            let isFull = AX.bool(element, AX.fullScreenAttribute) ?? false
            return AX.set(element, AX.fullScreenAttribute, AX.cfBool(!isFull)) == .success
        }
        // 不支持全屏时回退为缩放。
        guard let zoom = AX.element(element, kAXZoomButtonAttribute) else { return false }
        return AX.perform(zoom, kAXPressAction) == .success
    }
}

/// AXObserver 的 C 回调：在观察者线程上执行，转发给对应的 AppTracker。
private func axObserverCallback(_: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<AppTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification: notification as String, element: AXRef(element: element))
}
