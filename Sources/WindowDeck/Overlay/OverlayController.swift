import AppKit
import WindowDeckCore

/// 每块屏幕一个全屏覆盖层。
final class OverlayPanel: NSPanel {
    init(screen: NSScreen, theme: OverlayTheme) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // 盖住菜单栏与 Dock，但低于弹出菜单层级（保证提示、菜单仍可见）。
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        // "覆盖层主题"为跟随应用时为 nil，继承 NSApp.appearance（"应用主题"）。
        appearance = theme.appearance
    }

    // 接收键盘，同时不激活应用。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 覆盖层状态机：决定展示哪个视图，协调快照、缩略图、布局与动画。
@MainActor
final class OverlayController: OverlayContentDelegate {
    enum TriggerSource: Sendable {
        case gesture, hotkey, menu
    }

    private enum State: Equatable {
        case hidden
        case presenting(OverlayMode)
        case visible(OverlayMode)
        case dismissing
    }

    private var state: State = .hidden
    private var pending: (OverlayMode, TriggerSource)?
    private var panels: [(panel: OverlayPanel, content: OverlayContentView)] = []
    private var mode: OverlayMode = .deck
    private var exposePID: pid_t?
    /// Exposé 目标是浏览器时显示标签页（每次打开时重置为设置中的默认值，按 T 切换）。
    private var showsBrowserTabs = true

    private let catalog: WindowCatalog
    private let thumbnails: ThumbnailService
    private let settingsStore: SettingsStore
    private let browserTabs = BrowserTabService()

    init(catalog: WindowCatalog, thumbnails: ThumbnailService, settingsStore: SettingsStore) {
        self.catalog = catalog
        self.thumbnails = thumbnails
        self.settingsStore = settingsStore
        browserTabs.onChange = { [weak self] pid in
            guard let self, self.exposePID == pid, self.isShowingBrowserTabs else { return }
            // 收起动画期间（例如切换标签页后的刷新）不再重建内容。
            switch self.state {
            case .visible, .presenting: self.refreshContents()
            default: break
            }
        }
    }

    private var settings: AppSettings { settingsStore.settings }

    var isVisible: Bool { state != .hidden }

    // MARK: 触发

    func trigger(_ requested: OverlayMode, source: TriggerSource) {
        switch state {
        case .hidden:
            present(requested)
        case .presenting, .dismissing:
            // 动画期间的触发排队，只保留最后一个。
            pending = (requested, source)
        case let .visible(current):
            if source == .gesture {
                // 反向手势收起；同向手势忽略。
                if requested != current { dismiss(focusing: nil) }
            } else if requested == current {
                dismiss(focusing: nil)
            } else {
                switchMode(to: requested)
            }
        }
    }

    private func processPending() {
        guard let (mode, source) = pending else { return }
        pending = nil
        trigger(mode, source: source)
    }

    // MARK: 展示

    private func present(_ mode: OverlayMode) {
        // 必须在覆盖层成为 key 之前读取前台应用。
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == nil || front == selfPID { front = catalog.mostRecentAppPID }
        exposePID = front
        self.mode = mode
        showsBrowserTabs = settings.expose.showBrowserTabs
        refreshBrowserTabsIfNeeded()

        let snapshot = catalog.snapshot()
        let contexts = makeContexts(mode: mode, snapshot: snapshot)
        guard !contexts.isEmpty else { return }

        let mouseScreen = CoordinateConverter.screenWithMouse
        var keyContent: OverlayContentView?
        for (screen, context) in contexts {
            let panel = OverlayPanel(screen: screen, theme: settings.appearance.overlayTheme)
            let content = OverlayContentView(screen: screen, context: context, thumbnails: thumbnails)
            content.delegate = self
            panel.contentView = content
            panels.append((panel, content))
            if screen == mouseScreen || keyContent == nil { keyContent = content }
        }
        for (panel, content) in panels {
            panel.orderFrontRegardless()
            content.present()
        }
        if let keyContent, let panel = keyContent.window {
            panel.makeKey()
            panel.makeFirstResponder(keyContent)
        }
        state = .presenting(mode)
        Log.overlay.info("present \(mode == .deck ? "deck" : "expose", privacy: .public), \(snapshot.windows.count) windows")

        // 先用缓存渲染，同时按"可见卡片优先"刷新缩略图。
        if settings.showThumbnails {
            thumbnails.refresh(panels.flatMap { $0.content.visibleWindows })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case let .presenting(m) = self.state else { return }
                self.state = .visible(m)
                self.processPending()
            }
        }
    }

    // MARK: 浏览器标签页

    /// Exposé 的目标应用是受支持的浏览器（且设置中开启了标签页视图）。
    private var exposeBrowserPID: pid_t? {
        guard settings.expose.showBrowserTabs, let pid = exposePID,
              BrowserTabService.supports(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else { return nil }
        return pid
    }

    private var isShowingBrowserTabs: Bool {
        mode == .expose && showsBrowserTabs && exposeBrowserPID != nil
    }

    private func refreshBrowserTabsIfNeeded() {
        guard isShowingBrowserTabs, let pid = exposeBrowserPID else { return }
        browserTabs.refresh(pid: pid)
    }

    /// 当前标签页数据：匹配系统窗口，并按设置过滤无痕窗口。
    private func browserTabsState(snapshot: CatalogSnapshot) -> BrowserTabsState? {
        guard isShowingBrowserTabs, let pid = exposeBrowserPID else { return nil }
        let state = browserTabs.state(for: pid)
        guard case var .loaded(tabs) = state else { return state }
        if !settings.expose.includeIncognitoTabs {
            tabs.windows.removeAll(where: \.isIncognito)
        }
        let windows = snapshot.app(pid: pid).map { snapshot.windows(of: $0) } ?? []
        tabs.windows = BrowserTabMatcher.match(tabs.windows, to: windows)
        return .loaded(tabs)
    }

    /// 按屏幕分配窗口。
    private func makeContexts(mode: OverlayMode, snapshot: CatalogSnapshot) -> [(NSScreen, OverlayContext)] {
        let mouseScreen = CoordinateConverter.screenWithMouse ?? NSScreen.main
        let screens: [NSScreen]
        switch settings.multiDisplay {
        case .perScreen: screens = NSScreen.screens
        case .allOnMouseScreen: screens = mouseScreen.map { [$0] } ?? []
        }
        guard !screens.isEmpty else { return [] }

        var assignment: [ObjectIdentifier: Set<CGWindowID>] = [:]
        if screens.count == 1 {
            assignment[ObjectIdentifier(screens[0])] = Set(snapshot.windows.keys)
        } else {
            for window in snapshot.windows.values {
                let screen = CoordinateConverter.screen(forAX: window.frame).flatMap { s in screens.first { $0 == s } } ?? mouseScreen ?? screens[0]
                assignment[ObjectIdentifier(screen), default: []].insert(window.id)
            }
        }
        let tabsAvailable = mode == .expose && exposeBrowserPID != nil
        let tabsState = browserTabsState(snapshot: snapshot)
        return screens.map { screen in
            let isPrimary = screen == mouseScreen || screens.count == 1
            return (screen, OverlayContext(
                mode: mode,
                snapshot: snapshot,
                settings: settings,
                windowIDs: assignment[ObjectIdentifier(screen)] ?? [],
                exposePID: exposePID,
                includeAppsWithoutWindows: isPrimary,
                browserTabsAvailable: tabsAvailable,
                showsBrowserTabs: tabsAvailable && showsBrowserTabs,
                browserTabs: isPrimary ? tabsState : nil
            ))
        }
    }

    private func refreshContents(animation: OverlayContentView.Animation = .transition) {
        guard !panels.isEmpty else { return }
        let snapshot = catalog.snapshot()
        let contexts = makeContexts(mode: mode, snapshot: snapshot)
        for (_, content) in panels {
            guard let context = contexts.first(where: { $0.0 == content.screen })?.1 else { continue }
            content.update(context: context, animation: animation)
        }
        if settings.showThumbnails {
            thumbnails.refresh(panels.flatMap { $0.content.visibleWindows })
        }
    }

    private func switchMode(to mode: OverlayMode) {
        self.mode = mode
        state = .visible(mode)
        refreshBrowserTabsIfNeeded()
        refreshContents()
    }

    /// 窗口目录或配置变化时调用。
    func catalogDidChange() {
        switch state {
        case .visible, .presenting: refreshContents()
        default: break
        }
    }

    func thumbnailUpdated(_ id: CGWindowID, image: CGImage) {
        for (_, content) in panels { content.updateThumbnail(id, image: image) }
    }

    func screensDidChange() {
        if isVisible { dismiss(focusing: nil) }
    }

    // MARK: 收起

    func dismiss(focusing window: WindowInfo?) {
        switch state {
        case .visible, .presenting: break
        default: return
        }
        state = .dismissing
        if let window {
            catalog.perform(.focus(precise: settings.preciseFocus), on: window)
        }
        var remaining = panels.count
        let finish: @MainActor () -> Void = { [weak self] in
            remaining -= 1
            guard remaining <= 0, let self else { return }
            for (panel, _) in self.panels { panel.orderOut(nil) }
            self.panels.removeAll()
            self.state = .hidden
            self.processPending()
        }
        if panels.isEmpty {
            state = .hidden
            return
        }
        for (_, content) in panels {
            content.dismiss(focusing: window?.id, completion: finish)
        }
    }

    // MARK: OverlayContentDelegate

    func overlayFocus(_ window: WindowInfo, from content: OverlayContentView) {
        dismiss(focusing: window)
    }

    func overlayPerform(_ action: CardAction, window: WindowInfo, card: CardView, from content: OverlayContentView) {
        let windowAction: WindowAction
        switch action {
        case .close: windowAction = .close
        case .toggleMinimize: windowAction = .toggleMinimize
        case .green:
            // 全屏 / 缩放会切换桌面或改变窗口，先收起并聚焦，再执行。
            dismiss(focusing: window)
            let mode = settings.trafficLights.greenAction
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    self?.catalog.perform(.green(mode), on: window) { ok in
                        if !ok { NSSound.beep() }
                    }
                }
            }
            return
        case .focus, .hint:
            return
        }
        catalog.perform(windowAction, on: window) { [weak self, weak card, weak content] ok in
            guard let self else { return }
            guard ok else {
                card?.shake()
                content?.showToast(String(localized: "操作失败：该窗口不支持或应用未响应"))
                return
            }
            if self.settings.dismissAfterAction {
                self.dismiss(focusing: nil)
            } else if windowAction == .close {
                // 应用弹出"是否保存"之类的表单时，收起覆盖层并聚焦到该窗口。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.isVisible, self.catalog.window(window.id) != nil else { return }
                        self.catalog.windowHasSheet(window) { hasSheet in
                            if hasSheet { self.dismiss(focusing: window) }
                        }
                    }
                }
            }
        }
    }

    func overlayHideApp(_ pid: pid_t) {
        catalog.hideApp(pid)
    }

    func overlayQuitApp(_ pid: pid_t) {
        catalog.quitApp(pid)
    }

    func overlayActivateApp(_ pid: pid_t) {
        dismiss(focusing: nil)
        catalog.activateApp(pid)
    }

    func overlayDismiss() {
        dismiss(focusing: nil)
    }

    func overlaySwitchExposeApp(forward: Bool) {
        let snapshot = catalog.snapshot()
        let candidates = snapshot.apps.filter { !$0.windowIDs.isEmpty }.map(\.pid)
        guard !candidates.isEmpty else { return }
        let index = exposePID.flatMap { candidates.firstIndex(of: $0) }
        let next: Int
        if let index {
            next = (index + (forward ? 1 : -1) + candidates.count) % candidates.count
        } else {
            next = 0
        }
        exposePID = candidates[next]
        refreshBrowserTabsIfNeeded()
        refreshContents()
    }

    func overlayToggleBrowserTabs() {
        guard exposeBrowserPID != nil else { return }
        showsBrowserTabs.toggle()
        refreshBrowserTabsIfNeeded()
        refreshContents()
    }

    func overlayToggleBrowserTabGrouping() {
        // 写入设置后 settingsDidChange 会刷新覆盖层。
        settingsStore.update { $0.expose.tabGrouping = $0.expose.tabGrouping == .domain ? .window : .domain }
    }

    func overlayActivateTab(_ tab: BrowserTab, in window: BrowserWindowTabs, from content: OverlayContentView) {
        guard let pid = exposeBrowserPID else { return }
        // 先切换标签页再聚焦窗口，避免窗口先以旧标签页出现；找不到对应系统窗口时由脚本把窗口提到最前。
        let systemWindow = window.windowID.flatMap { catalog.window($0) }
        dismiss(focusing: nil)
        browserTabs.activate(tab, in: window, pid: pid, raiseWindow: systemWindow == nil) { [weak self] ok in
            guard let self else { return }
            if let systemWindow {
                self.catalog.perform(.focus(precise: self.settings.preciseFocus), on: systemWindow)
            } else {
                self.catalog.activateApp(pid)
            }
            if !ok { NSSound.beep() }
            // 更新缓存，下次打开时当前标签页是对的。
            self.browserTabs.refresh(pid: pid)
        }
    }

    func overlayCloseTab(_ tab: BrowserTab, in window: BrowserWindowTabs, from content: OverlayContentView) {
        guard let pid = exposeBrowserPID else { return }
        browserTabs.close(tab, in: window, pid: pid) { [weak self, weak content] ok in
            guard let self else { return }
            if !ok {
                content?.showToast(String(localized: "关闭标签页失败：浏览器未响应"))
                self.refreshContents()
            } else if self.settings.dismissAfterAction {
                self.dismiss(focusing: nil)
            }
        }
    }

    func overlayBrowserTabsMessageAction() {
        guard let pid = exposeBrowserPID else { return }
        switch browserTabs.state(for: pid) {
        case .needsPermission:
            // 系统授权框会被覆盖层挡住：先收起。
            dismiss(focusing: nil)
            browserTabs.requestPermission(pid: pid)
        case .denied:
            dismiss(focusing: nil)
            BrowserTabService.openAutomationSettings()
        case .failed, .loading, .loaded:
            browserTabs.refresh(pid: pid)
        }
    }
}

extension WindowAction: Equatable {
    static func == (lhs: WindowAction, rhs: WindowAction) -> Bool {
        switch (lhs, rhs) {
        case (.close, .close), (.toggleMinimize, .toggleMinimize): true
        case let (.focus(a), .focus(b)): a == b
        case let (.green(a), .green(b)): a == b
        default: false
        }
    }
}
