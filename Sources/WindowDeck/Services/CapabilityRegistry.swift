import Foundation

/// 启动时探测私有能力，UI 据此降级。
struct CapabilityRegistry: Sendable {
    struct Item: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let available: Bool
        let fallback: String
    }

    let windowID: Bool
    let spaces: Bool
    let otherSpaceAX: Bool
    let gesture: Bool
    let preciseFocus: Bool

    static func probe() -> CapabilityRegistry {
        CapabilityRegistry(
            windowID: AXPrivate.getWindowFn != nil,
            // 轻量自检：连接 ID 合理才认为 SkyLight 可用。
            spaces: SkyLight.connection != nil && SkyLight.copyManagedDisplaySpacesFn != nil && SkyLight.copySpacesForWindowsFn != nil,
            otherSpaceAX: AXPrivate.createWithRemoteTokenFn != nil && AXPrivate.getWindowFn != nil,
            gesture: Multitouch.isAvailable,
            preciseFocus: SkyLight.supportsPreciseFocus
        )
    }

    var items: [Item] {
        [
            Item(name: String(localized: "窗口 ID（_AXUIElementGetWindow）"), available: windowID, fallback: String(localized: "无法识别窗口，基本功能不可用")),
            Item(name: String(localized: "桌面（Space）信息（SkyLight）"), available: spaces, fallback: String(localized: "只展示当前桌面的窗口")),
            Item(name: String(localized: "其他桌面窗口操作（远程 AX 令牌）"), available: otherSpaceAX, fallback: String(localized: "其他桌面的窗口只读，点击时激活应用")),
            Item(name: String(localized: "触控板手势（MultitouchSupport）"), available: gesture, fallback: String(localized: "手势不可用，请改用快捷键")),
            Item(name: String(localized: "精确聚焦（SkyLight）"), available: preciseFocus, fallback: String(localized: "使用 AX 置前 + 抬升窗口")),
        ]
    }
}
