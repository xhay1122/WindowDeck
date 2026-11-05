import CoreGraphics
import Foundation

/// 窗口支持的操作，决定红绿灯是否可点。
public struct WindowCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let close = WindowCapabilities(rawValue: 1 << 0)
    public static let minimize = WindowCapabilities(rawValue: 1 << 1)
    public static let fullscreen = WindowCapabilities(rawValue: 1 << 2)
    public static let zoom = WindowCapabilities(rawValue: 1 << 3)
    /// 有可操作的 AX 元素（聚焦 / 红绿灯）。其他桌面上未能解析到 AX 元素的窗口为只读。
    public static let focus = WindowCapabilities(rawValue: 1 << 4)

    public static let all: WindowCapabilities = [.close, .minimize, .fullscreen, .zoom, .focus]
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    /// 原始标题，可能为空。
    public var title: String
    /// 全局坐标，主屏左上角为原点、y 向下（与 AX / CG 一致）。
    public var frame: CGRect
    public var isMinimized: Bool
    public var isFullscreen: Bool
    public var isOnCurrentSpace: Bool
    public var capabilities: WindowCapabilities
    /// MRU 排序依据。
    public var lastFocusedAt: Date?

    public init(
        id: CGWindowID,
        pid: pid_t,
        title: String,
        frame: CGRect,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        isOnCurrentSpace: Bool = true,
        capabilities: WindowCapabilities = .all,
        lastFocusedAt: Date? = nil
    ) {
        self.id = id
        self.pid = pid
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isOnCurrentSpace = isOnCurrentSpace
        self.capabilities = capabilities
        self.lastFocusedAt = lastFocusedAt
    }
}

public struct AppInfo: Identifiable, Hashable, Sendable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let bundleID: String?
    public var name: String
    /// Cmd+H 隐藏。
    public var isHidden: Bool
    /// AX 调用超时，视为未响应。
    public var isUnresponsive: Bool
    /// 按 MRU 排序。
    public var windowIDs: [CGWindowID]
    public var lastActivatedAt: Date?

    public init(
        pid: pid_t,
        bundleID: String?,
        name: String,
        isHidden: Bool = false,
        isUnresponsive: Bool = false,
        windowIDs: [CGWindowID] = [],
        lastActivatedAt: Date? = nil
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isHidden = isHidden
        self.isUnresponsive = isUnresponsive
        self.windowIDs = windowIDs
        self.lastActivatedAt = lastActivatedAt
    }
}

public struct CatalogSnapshot: Sendable {
    /// 按 MRU 排序。
    public let apps: [AppInfo]
    public let windows: [CGWindowID: WindowInfo]
    public let frontmostPID: pid_t?
    public let takenAt: Date

    public init(apps: [AppInfo], windows: [CGWindowID: WindowInfo], frontmostPID: pid_t?, takenAt: Date = Date()) {
        self.apps = apps
        self.windows = windows
        self.frontmostPID = frontmostPID
        self.takenAt = takenAt
    }

    public static let empty = CatalogSnapshot(apps: [], windows: [:], frontmostPID: nil)

    public func app(pid: pid_t) -> AppInfo? {
        apps.first { $0.pid == pid }
    }

    public func windows(of app: AppInfo) -> [WindowInfo] {
        app.windowIDs.compactMap { windows[$0] }
    }
}

/// MRU 排序：有时间戳的在前（新的在前），没有时间戳的按 fallback 顺序（例如 z-order）排在后面。
public enum MRUOrdering {
    public static func sort<T>(
        _ items: [T],
        timestamp: (T) -> Date?,
        fallbackRank: (T) -> Int
    ) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let l = timestamp(lhs.element)
            let r = timestamp(rhs.element)
            switch (l, r) {
            case let (l?, r?) where l != r:
                return l > r
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                let lr = fallbackRank(lhs.element)
                let rr = fallbackRank(rhs.element)
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
