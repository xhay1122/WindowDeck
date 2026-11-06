import CoreGraphics
import Foundation

/// 浏览器脚本字典里对象的 `id`（Chrome 实际返回整数，字典声明为文本，两种都兼容）。
public enum ScriptObjectID: Hashable, Sendable {
    case integer(Int)
    case text(String)
}

/// 浏览器的一个标签页（通过 Apple Events 读取）。
public struct BrowserTab: Identifiable, Hashable, Sendable {
    public let id: ScriptObjectID
    public var title: String
    public var url: String

    public init(id: ScriptObjectID, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }

    /// 用于展示的域名（去掉 `www.`）；非网页地址（例如 `chrome://`）返回 scheme + host。
    public var displayHost: String {
        guard let components = URLComponents(string: url) else { return url }
        let host = components.host ?? ""
        switch components.scheme?.lowercased() {
        case "http", "https":
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        case let scheme?:
            return host.isEmpty ? scheme + ":" : scheme + "://" + host
        case nil:
            return host
        }
    }

    /// 分组用的域名：http(s) 取主机名的最后三段（`xx.xx.xx`，例如 mail.google.com、a.b.example.com → b.example.com），
    /// 开头的 `www.` 去掉（www.github.com → github.com）；IP 地址用完整地址；其他 scheme 取 `scheme://`（chrome://、file://）。
    public var groupingDomain: String {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else { return displayHost }
        guard scheme == "http" || scheme == "https" else { return scheme + "://" }
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 3, !labels.allSatisfy({ Int($0) != nil }) else { return host }
        return labels.suffix(3).joined(separator: ".")
    }
}

/// 浏览器的一个窗口及其标签页。
public struct BrowserWindowTabs: Identifiable, Hashable, Sendable {
    /// 浏览器脚本里的窗口 id（不是 `CGWindowID`）。
    public let id: ScriptObjectID
    /// 窗口标题（即当前标签页的标题）。
    public var title: String
    /// 全局坐标，主屏左上角为原点、y 向下（与 AX / CG 一致）。
    public var bounds: CGRect?
    public var isIncognito: Bool
    public var isMinimized: Bool
    /// 当前标签页在 `tabs` 中的下标（从 0 开始）。
    public var activeTabIndex: Int?
    public var tabs: [BrowserTab]
    /// 匹配到的系统窗口；匹配不到时为 nil（切换时退化为用脚本把窗口提到最前）。
    public var windowID: CGWindowID?

    public init(
        id: ScriptObjectID,
        title: String,
        bounds: CGRect?,
        isIncognito: Bool = false,
        isMinimized: Bool = false,
        activeTabIndex: Int?,
        tabs: [BrowserTab],
        windowID: CGWindowID? = nil
    ) {
        self.id = id
        self.title = title
        self.bounds = bounds
        self.isIncognito = isIncognito
        self.isMinimized = isMinimized
        self.activeTabIndex = activeTabIndex
        self.tabs = tabs
        self.windowID = windowID
    }

    public var activeTab: BrowserTab? {
        activeTabIndex.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil }
    }
}

/// 一次读取的结果。`windows` 按浏览器的前后顺序（最前的窗口在前）。
public struct BrowserTabsSnapshot: Hashable, Sendable {
    public let pid: pid_t
    public var windows: [BrowserWindowTabs]
    public let takenAt: Date

    public init(pid: pid_t, windows: [BrowserWindowTabs], takenAt: Date = Date()) {
        self.pid = pid
        self.windows = windows
        self.takenAt = takenAt
    }

    public var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }
}

/// 把浏览器脚本里的窗口对应到系统窗口（`CGWindowID`）。
/// 两边都没有共同的 id：先按位置尺寸匹配（误差在 `tolerance` 内，标题相同的优先），再对剩下的按唯一标题匹配。
public enum BrowserTabMatcher {
    public static func match(
        _ browserWindows: [BrowserWindowTabs],
        to windows: [WindowInfo],
        tolerance: CGFloat = 4
    ) -> [BrowserWindowTabs] {
        var result = browserWindows.map { window -> BrowserWindowTabs in
            var w = window
            w.windowID = nil
            return w
        }
        var usedWindows = Set<CGWindowID>()

        // 1. 位置尺寸。
        var pairs: [(browser: Int, window: CGWindowID, score: CGFloat)] = []
        for (index, browser) in result.enumerated() {
            guard let bounds = browser.bounds else { continue }
            for window in windows {
                let f = window.frame
                let distance = max(abs(f.minX - bounds.minX), abs(f.minY - bounds.minY), abs(f.width - bounds.width), abs(f.height - bounds.height))
                guard distance <= tolerance else { continue }
                // 标题相同时加分，用来区分完全重叠的窗口。
                let score = distance + (titleMatches(system: window.title, browser: browser.title) ? 0 : tolerance + 1)
                pairs.append((index, window.id, score))
            }
        }
        pairs.sort { $0.score < $1.score }
        for pair in pairs where result[pair.browser].windowID == nil && !usedWindows.contains(pair.window) {
            result[pair.browser].windowID = pair.window
            usedWindows.insert(pair.window)
        }

        // 2. 唯一标题。
        for index in result.indices where result[index].windowID == nil {
            let title = result[index].title
            guard !title.isEmpty,
                  result.filter({ $0.title == title }).count == 1 else { continue }
            let candidates = windows.filter { titleMatches(system: $0.title, browser: title) && !usedWindows.contains($0.id) }
            if candidates.count == 1, let window = candidates.first {
                result[index].windowID = window.id
                usedWindows.insert(window.id)
            }
        }
        return result
    }

    /// 系统窗口标题（AX）与浏览器窗口标题 / 标签标题是否一致。
    /// Chrome 的 AX 标题是"标签标题 - [属于“分组”群组 - ]Google Chrome[ - 用户名]"，脚本里的窗口名只有标签标题，因此按前缀比较。
    public static func titleMatches(system: String, browser: String) -> Bool {
        guard !browser.isEmpty else { return system.isEmpty }
        return system == browser || system.hasPrefix(browser + " - ")
    }
}

/// 标签页在快照中的位置（窗口下标、标签下标）。
public struct BrowserTabPosition: Hashable, Sendable {
    public var window: Int
    public var tab: Int

    public init(window: Int, tab: Int) {
        self.window = window
        self.tab = tab
    }
}

/// 按域名分组的一组标签页。`domain` 为 nil 表示"其他网站"（只有一个标签页的域名合并而成）。
public struct BrowserTabDomainGroup: Hashable, Sendable {
    public var domain: String?
    public var positions: [BrowserTabPosition]

    public init(domain: String?, positions: [BrowserTabPosition]) {
        self.domain = domain
        self.positions = positions
    }
}

public enum BrowserTabGrouper {
    /// 按域名分组：标签数多的在前（相同时按首次出现顺序），组内保持窗口顺序 + 标签顺序；
    /// 只有一个标签页的域名不少于 2 个时合并为"其他网站"放在最后。
    public static func groupByDomain(_ windows: [BrowserWindowTabs]) -> [BrowserTabDomainGroup] {
        var order: [String] = []
        var buckets: [String: [BrowserTabPosition]] = [:]
        for (w, window) in windows.enumerated() {
            for (t, tab) in window.tabs.enumerated() {
                let domain = tab.groupingDomain
                if buckets[domain] == nil { order.append(domain) }
                buckets[domain, default: []].append(BrowserTabPosition(window: w, tab: t))
            }
        }
        let firstSeen = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let singles = order.filter { buckets[$0]?.count == 1 }
        let mergeSingles = singles.count >= 2
        var groups = order
            .filter { !mergeSingles || (buckets[$0]?.count ?? 0) > 1 }
            .sorted { a, b in
                let ca = buckets[a]?.count ?? 0
                let cb = buckets[b]?.count ?? 0
                return ca != cb ? ca > cb : (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
            }
            .map { BrowserTabDomainGroup(domain: $0, positions: buckets[$0] ?? []) }
        if mergeSingles {
            let positions = singles.flatMap { buckets[$0] ?? [] }.sorted { ($0.window, $0.tab) < ($1.window, $1.tab) }
            groups.append(BrowserTabDomainGroup(domain: nil, positions: positions))
        }
        return groups
    }
}
