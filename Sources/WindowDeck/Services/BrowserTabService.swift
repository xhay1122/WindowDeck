import AppKit
import WindowDeckCore

/// 浏览器标签页视图的数据状态。
enum BrowserTabsState: Sendable, Equatable {
    case loading
    /// 还没询问过"自动化"权限。
    case needsPermission
    /// 用户拒绝了"自动化"权限，需要到系统设置中打开。
    case denied
    /// 浏览器无响应或回复异常。
    case failed
    case loaded(BrowserTabsSnapshot)
}

/// 通过 Apple Events 读取 / 切换 / 关闭浏览器标签页。
/// Apple Event 是同步 IPC：全部在一个后台串行队列上执行，结果回到主线程；每个 pid 缓存最近一次结果，打开视图时先用缓存再刷新。
@MainActor
final class BrowserTabService {
    /// 使用 Chrome 脚本字典的浏览器。其他 Chromium 浏览器（Edge、Brave 等）字典基本一致，但未经验证，暂不加入。
    static let supportedBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
    ]

    static func supports(bundleID: String?) -> Bool {
        bundleID.map(supportedBundleIDs.contains) ?? false
    }

    /// 某个 pid 的状态变化（读取完成 / 标签页被关闭等）。
    var onChange: ((pid_t) -> Void)?

    private let queue = DispatchQueue(label: "com.windowdeck.browsertabs", qos: .userInitiated)
    private var states: [pid_t: BrowserTabsState] = [:]
    private var inFlight: Set<pid_t> = []
    private var refreshAgain: Set<pid_t> = []

    func state(for pid: pid_t) -> BrowserTabsState {
        states[pid] ?? .loading
    }

    /// 应用退出后清理缓存。
    func forget(_ pid: pid_t) {
        states[pid] = nil
    }

    /// 后台刷新；已有结果时保留旧结果直到新结果返回。同一个 pid 同时只有一个请求，期间的刷新合并为一次。
    func refresh(pid: pid_t) {
        guard !inFlight.contains(pid) else {
            refreshAgain.insert(pid)
            return
        }
        inFlight.insert(pid)
        queue.async { [weak self] in
            let state = Self.load(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight.remove(pid)
                    // 刷新失败时保留上一次成功的结果，避免列表闪烁成错误页。
                    if case .failed = state, case .loaded = self.states[pid] {
                        Log.overlay.error("browser tabs refresh failed, keeping cached result")
                    } else {
                        self.states[pid] = state
                    }
                    self.onChange?(pid)
                    if self.refreshAgain.remove(pid) != nil { self.refresh(pid: pid) }
                }
            }
        }
    }

    private nonisolated static func load(pid: pid_t) -> BrowserTabsState {
        switch ChromeScripting.determinePermission(pid: pid, askUserIfNeeded: false) {
        case .success: break
        case .failure(.needsConsent): return .needsPermission
        case .failure(.notPermitted): return .denied
        case let .failure(error):
            Log.overlay.error("browser automation permission check failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
        let started = Date()
        var result = ChromeScripting.fetchWindows(pid: pid)
        // 读取期间标签页变化导致列表长度不一致时重试一次。
        if case .failure(.malformedReply) = result { result = ChromeScripting.fetchWindows(pid: pid) }
        switch result {
        case let .success(windows):
            Log.overlay.info("browser tabs: \(windows.count) windows, \(windows.reduce(0) { $0 + $1.tabs.count }) tabs in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return .loaded(BrowserTabsSnapshot(pid: pid, windows: windows))
        case .failure(.notPermitted):
            return .denied
        case .failure(.needsConsent):
            return .needsPermission
        case let .failure(error):
            Log.overlay.error("browser tabs fetch failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// 弹出系统的"自动化"授权框（阻塞到用户选择，因此在后台执行），完成后刷新。
    func requestPermission(pid: pid_t) {
        queue.async { [weak self] in
            let result = ChromeScripting.determinePermission(pid: pid, askUserIfNeeded: true)
            Log.overlay.info("browser automation permission request: \(String(describing: result), privacy: .public)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh(pid: pid) }
            }
        }
    }

    /// 切换到标签页。`raiseWindow` 为 true 时同时用脚本把窗口提到浏览器最前（没有对应系统窗口时使用）。
    func activate(_ tab: BrowserTab, in window: BrowserWindowTabs, pid: pid_t, raiseWindow: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        let tabID = tab.id
        let windowID = window.id
        queue.async {
            let result = ChromeScripting.activateTab(tabID, inWindow: windowID, pid: pid, raiseWindow: raiseWindow)
            if case let .failure(error) = result {
                Log.overlay.error("activate tab failed: \(String(describing: error), privacy: .public)")
            }
            let ok = (try? result.get()) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(ok) }
            }
        }
    }

    func close(_ tab: BrowserTab, in window: BrowserWindowTabs, pid: pid_t, completion: @escaping @MainActor (Bool) -> Void) {
        let tabID = tab.id
        let windowID = window.id
        queue.async { [weak self] in
            let result = ChromeScripting.closeTab(tabID, inWindow: windowID, pid: pid)
            if case let .failure(error) = result {
                Log.overlay.error("close tab failed: \(String(describing: error), privacy: .public)")
            }
            let ok = (try? result.get()) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(ok)
                    self?.refresh(pid: pid)
                }
            }
        }
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}
