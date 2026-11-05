import AppKit
import CoreGraphics
import Foundation
import WindowDeckCore

/// 维护全部应用与窗口的内存模型，提供不可变快照。事件驱动更新，触发时只读快照。
@MainActor
final class WindowCatalog {
    private struct AppRecord {
        let pid: pid_t
        let bundleID: String?
        var name: String
        var isHidden: Bool
        var isUnresponsive = false
        var windows: [CGWindowID: WindowInfo] = [:]
        var lastActivatedAt: Date?
        let tracker: AppTracker
    }

    /// 系统 UI 进程，永远不展示。
    static let builtinExcludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.screencaptureui",
    ]

    var onChange: (() -> Void)?
    /// 窗口失去焦点（用于缩略图预热）。
    var onWindowLostFocus: ((WindowInfo) -> Void)?

    private(set) var frontmostPID: pid_t?
    private var records: [pid_t: AppRecord] = [:]
    private var lastFocused: [CGWindowID: Date] = [:]
    private var readOnlyOtherSpace: [pid_t: [CGWindowID: WindowInfo]] = [:]
    private var globallyFocusedWindow: CGWindowID?
    private var notificationTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var changeScheduled = false
    private var scanScheduled = false
    private var isStarted = false

    private let settingsStore: SettingsStore
    private let capabilities: CapabilityRegistry
    private let scanner = OtherSpaceScanner()
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init(settingsStore: SettingsStore, capabilities: CapabilityRegistry) {
        self.settingsStore = settingsStore
        self.capabilities = capabilities
    }

    private var settings: AppSettings { settingsStore.settings }

    // MARK: 生命周期

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // 进程级默认超时：窗口元素不继承应用元素上设置的超时，默认值长达 6 秒。
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { handler(app) }
            }
            notificationTokens.append(token)
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.track(app)
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.untrack(app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.didActivate(app)
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.records[app.processIdentifier]?.isHidden = true
            self.scheduleChange()
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.records[app.processIdentifier]?.isHidden = false
            self.scheduleChange()
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.refreshAll()
        }
        on(NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.refreshAll()
        }
        // 锁屏期间 AX 可能返回空窗口列表，解锁后未被激活的应用不会再收到刷新，需要主动全量刷新。
        on(NSWorkspace.screensDidWakeNotification) { [weak self] _ in
            self?.refreshAfterUnlock()
        }
        on(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.refreshAfterUnlock()
        }
        let unlockToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAfterUnlock() }
        }
        distributedTokens.append(unlockToken)

        if let front = NSWorkspace.shared.frontmostApplication {
            frontmostPID = front.processIdentifier
        }
        syncTrackedApps()
        if let pid = frontmostPID {
            records[pid]?.lastActivatedAt = Date()
            records[pid]?.tracker.reportFocusedWindow()
        }
        scheduleOtherSpaceScan()
        Log.catalog.info("catalog started, tracking \(self.records.count) apps")
    }

    func stop() {
        for token in notificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
        for token in distributedTokens {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        distributedTokens.removeAll()
        for record in records.values { record.tracker.stop() }
        records.removeAll()
        isStarted = false
    }

    /// 配置变化（排除列表、是否包含 accessory 应用）后重新同步。
    func syncTrackedApps() {
        guard isStarted else { return }
        let running = NSWorkspace.shared.runningApplications
        let eligible = Set(running.filter(isEligible).map(\.processIdentifier))
        for pid in records.keys where !eligible.contains(pid) {
            untrack(pid)
        }
        for app in running where eligible.contains(app.processIdentifier) {
            track(app)
        }
    }

    func refreshAll() {
        for record in records.values { record.tracker.scheduleRefresh(after: 0.05) }
        scheduleOtherSpaceScan()
    }

    /// 解锁后立即刷新一次；刚解锁时 AX 可能尚未就绪，稍后再补一次。
    private func refreshAfterUnlock() {
        refreshAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    private func isEligible(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != selfPID, !app.isTerminated else { return false }
        switch app.activationPolicy {
        case .regular: break
        case .accessory: guard settings.includeAccessoryApps else { return false }
        default: return false
        }
        if let bundleID = app.bundleIdentifier {
            if Self.builtinExcludedBundleIDs.contains(bundleID) || settings.excludedBundleIDs.contains(bundleID) {
                return false
            }
        }
        return true
    }

    private func track(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard records[pid] == nil, isEligible(app) else { return }
        let tracker = AppTracker(pid: pid) { [weak self] event in
            // 用主队列（FIFO）而不是 Task，保证同一应用的事件按顺序合并。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        records[pid] = AppRecord(
            pid: pid,
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "\(pid)",
            isHidden: app.isHidden,
            tracker: tracker
        )
        tracker.start()
    }

    private func untrack(_ pid: pid_t) {
        guard let record = records.removeValue(forKey: pid) else { return }
        record.tracker.stop()
        for id in record.windows.keys { lastFocused[id] = nil }
        readOnlyOtherSpace[pid] = nil
        scheduleChange()
    }

    private func didActivate(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != selfPID else { return }
        frontmostPID = pid
        if records[pid] == nil { track(app) }
        records[pid]?.lastActivatedAt = Date()
        records[pid]?.tracker.reportFocusedWindow()
        scheduleChange()
    }

    // MARK: 事件合并

    private func handle(_ event: AppTrackerEvent) {
        switch event {
        case let .windows(pid, windows):
            guard var record = records[pid] else { return }
            let oldIDs = Set(record.windows.keys)
            var dict: [CGWindowID: WindowInfo] = [:]
            for var window in windows {
                window.lastFocusedAt = lastFocused[window.id]
                dict[window.id] = window
            }
            record.windows = dict
            records[pid] = record
            for id in oldIDs.subtracting(dict.keys) { lastFocused[id] = nil }
            if oldIDs != Set(dict.keys) { scheduleOtherSpaceScan() }
            scheduleChange()

        case let .focused(pid, windowID):
            lastFocused[windowID] = Date()
            records[pid]?.windows[windowID]?.lastFocusedAt = lastFocused[windowID]
            if pid == frontmostPID, globallyFocusedWindow != windowID {
                let previous = globallyFocusedWindow
                globallyFocusedWindow = windowID
                if let previous, let info = window(previous) {
                    onWindowLostFocus?(info)
                }
            }
            scheduleChange()

        case let .unresponsive(pid, value):
            records[pid]?.isUnresponsive = value
            scheduleChange()
        }
    }

    /// 16ms 内的多次变更合并为一次通知。
    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeScheduled = false
                self.onChange?()
            }
        }
    }

    // MARK: 其他 Space

    private func scheduleOtherSpaceScan() {
        guard capabilities.spaces, settings.showWindowsFromOtherSpaces, !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.runOtherSpaceScan() }
        }
    }

    private func runOtherSpaceScan() {
        scanScheduled = false
        let known = Set(records.values.flatMap { $0.windows.keys })
        let tracked = Set(records.keys)
        scanner.scan(knownIDs: known, trackedPIDs: tracked) { [weak self] candidates in
            Task { @MainActor [weak self] in self?.applyScan(candidates) }
        }
    }

    private func applyScan(_ candidates: [pid_t: [OtherSpaceScanner.Candidate]]) {
        for pid in readOnlyOtherSpace.keys where candidates[pid] == nil {
            readOnlyOtherSpace[pid] = nil
        }
        for (pid, list) in candidates {
            guard let tracker = records[pid]?.tracker else { continue }
            let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            tracker.resolveRemoteWindows(Set(byID.keys), budget: 0.15) { [weak self] unresolved in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 无法解析到 AX 元素的窗口：有标题才只读展示，避免把辅助窗口当成用户窗口。
                    var readOnly: [CGWindowID: WindowInfo] = [:]
                    for id in unresolved {
                        guard let c = byID[id], !c.title.isEmpty else { continue }
                        readOnly[id] = WindowInfo(id: id, pid: pid, title: c.title, frame: c.frame, isOnCurrentSpace: false, capabilities: [])
                    }
                    self.readOnlyOtherSpace[pid] = readOnly.isEmpty ? nil : readOnly
                    self.scheduleChange()
                }
            }
        }
        scheduleChange()
    }

    // MARK: 快照

    func window(_ id: CGWindowID) -> WindowInfo? {
        for record in records.values {
            if let w = record.windows[id] { return w }
        }
        for dict in readOnlyOtherSpace.values {
            if let w = dict[id] { return w }
        }
        return nil
    }

    func snapshot() -> CatalogSnapshot {
        let s = settings
        // 屏幕上窗口的前后顺序（z-order）与层级。
        var zIndex: [CGWindowID: Int] = [:]
        var layer: [CGWindowID: Int] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (index, info) in list.enumerated() {
                guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
                zIndex[id] = index
                layer[id] = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            }
        }
        let farAway = Int.max / 2

        var apps: [AppInfo] = []
        var windows: [CGWindowID: WindowInfo] = [:]
        for record in records.values {
            if record.isHidden, !s.showHiddenApps { continue }
            var list = Array(record.windows.values)
            if s.showWindowsFromOtherSpaces, let extra = readOnlyOtherSpace[record.pid] {
                list += extra.values.filter { record.windows[$0.id] == nil }
            }
            list = list.filter { w in
                if let l = layer[w.id], l != 0 { return false }
                if w.isMinimized, !s.showMinimized { return false }
                if !w.isOnCurrentSpace, !s.showWindowsFromOtherSpaces { return false }
                return true
            }
            let sorted = MRUOrdering.sort(list, timestamp: { $0.lastFocusedAt }, fallbackRank: { w in
                // 当前桌面可见窗口按 z-order，其次已最小化，最后其他桌面。
                if let z = zIndex[w.id] { return z }
                return w.isMinimized ? farAway : farAway + 1
            })
            for w in sorted { windows[w.id] = w }
            apps.append(AppInfo(
                pid: record.pid,
                bundleID: record.bundleID,
                name: record.name,
                isHidden: record.isHidden,
                isUnresponsive: record.isUnresponsive,
                windowIDs: sorted.map(\.id),
                lastActivatedAt: record.lastActivatedAt
            ))
        }
        let sortedApps = MRUOrdering.sort(apps, timestamp: { $0.lastActivatedAt }, fallbackRank: { app in
            app.windowIDs.compactMap { zIndex[$0] }.min() ?? farAway
        })
        return CatalogSnapshot(apps: sortedApps, windows: windows, frontmostPID: frontmostPID)
    }

    /// 最近激活的应用（排除自身），用于 Exposé 的"当前应用"。
    var mostRecentAppPID: pid_t? {
        records.values
            .filter { $0.lastActivatedAt != nil }
            .max { $0.lastActivatedAt! < $1.lastActivatedAt! }?
            .pid
    }

    // MARK: 操作

    func perform(_ action: WindowAction, on window: WindowInfo, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let record = records[window.pid] else {
            completion?(false)
            return
        }
        if case .focus = action {
            let app = NSRunningApplication(processIdentifier: window.pid)
            if record.isHidden { app?.unhide() }
            // 只读窗口（其他桌面且无 AX 元素）：退化为激活应用。
            if !window.capabilities.contains(.focus) {
                app?.activate()
                completion?(app != nil)
                return
            }
        }
        record.tracker.perform(action, windowID: window.id) { ok in
            Task { @MainActor in completion?(ok) }
        }
    }

    func windowHasSheet(_ window: WindowInfo, completion: @escaping @MainActor (Bool) -> Void) {
        guard let tracker = records[window.pid]?.tracker else {
            completion(false)
            return
        }
        tracker.hasSheet(windowID: window.id) { hasSheet in
            Task { @MainActor in completion(hasSheet) }
        }
    }

    func hideApp(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    func quitApp(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func activateApp(_ pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        app?.unhide()
        app?.activate()
    }
}

/// 在后台扫描其他 Space 上的窗口（CGWindowList + SkyLight 过滤）。
final class OtherSpaceScanner: @unchecked Sendable {
    struct Candidate: Sendable {
        let id: CGWindowID
        let pid: pid_t
        let title: String
        let frame: CGRect
    }

    private let queue = DispatchQueue(label: "com.windowdeck.space-scan", qos: .utility)

    func scan(knownIDs: Set<CGWindowID>, trackedPIDs: Set<pid_t>, completion: @escaping @Sendable ([pid_t: [Candidate]]) -> Void) {
        queue.async {
            let current = SkyLight.currentSpaceIDs()
            guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                completion([:])
                return
            }
            var result: [pid_t: [Candidate]] = [:]
            for info in list {
                guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      !knownIDs.contains(id),
                      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      trackedPIDs.contains(pid),
                      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.width >= AppTracker.minimumWindowSize.width,
                      bounds.height >= AppTracker.minimumWindowSize.height
                else { continue }
                // 不受 WindowServer Space 管理的窗口不是用户窗口；在当前 Space 上的窗口 AX 已经返回过。
                guard let spaces = SkyLight.spaceIDs(for: id), !spaces.isEmpty,
                      current.isEmpty || Set(spaces).isDisjoint(with: current) else { continue }
                let title = info[kCGWindowName as String] as? String ?? ""
                result[pid, default: []].append(Candidate(id: id, pid: pid, title: title, frame: bounds))
            }
            completion(result)
        }
    }
}
