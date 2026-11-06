import Foundation

public enum ThumbnailQuality: String, Codable, Sendable, CaseIterable {
    case low, balanced, high

    /// 缩略图最长边像素上限（实际取 min(窗口原始像素, 上限)）。
    /// Retina 下 Deck 卡片最宽约 1120px，Exposé 卡片可接近窗口原尺寸，上限过低会被放大显示而发糊。
    public var maxPixelDimension: Double {
        switch self {
        case .low: 960
        case .balanced: 1600
        case .high: 2560
        }
    }
}

public enum TrafficLightVisibility: String, Codable, Sendable, CaseIterable {
    case onHover, always, never
}

public enum GreenAction: String, Codable, Sendable, CaseIterable {
    case fullscreen, zoom
}

public enum CloseConfirmation: String, Codable, Sendable, CaseIterable {
    /// 直接关闭（与系统一致）。
    case none
    /// 按住 Option 才执行。
    case optionKey
    /// 再点一次确认。
    case clickTwice
}

public enum ReduceMotionMode: String, Codable, Sendable, CaseIterable {
    case system, on, off
}

/// 界面主题：设置窗口与覆盖层共用。
public enum AppTheme: String, Codable, Sendable, CaseIterable {
    /// 跟随系统的浅色 / 深色外观。
    case system, light, dark
}

/// 覆盖层（牌堆 / 当前应用）主题，可独立于应用主题。
public enum OverlayTheme: String, Codable, Sendable, CaseIterable {
    /// 与应用主题一致。
    case followApp, light, dark
}

public enum MultiDisplayMode: String, Codable, Sendable, CaseIterable {
    /// 每块屏幕显示本屏的窗口（与系统一致）。
    case perScreen
    /// 全部集中到鼠标所在的屏幕。
    case allOnMouseScreen
}

/// 快捷键：Carbon 虚拟键码 + Carbon 修饰键掩码。
public struct KeyCombo: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

public struct GestureSettings: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    /// 3 或 4。
    public var fingers: Int = 3
    /// 0…1，越大越灵敏。
    public var sensitivity: Double = 0.5

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSettings()
        enabled = c.value(.enabled, default: d.enabled)
        fingers = c.value(.fingers, default: d.fingers) == 4 ? 4 : 3
        sensitivity = min(max(c.value(.sensitivity, default: d.sensitivity), 0), 1)
    }

    /// 灵敏度映射到位移阈值：0 → 0.18，1 → 0.06。
    public var distanceThreshold: Double { 0.18 - 0.12 * sensitivity }
}

public struct HotkeySettings: Codable, Sendable, Equatable {
    /// 默认不配置。
    public var deck: KeyCombo?
    public var expose: KeyCombo?

    public init(deck: KeyCombo? = nil, expose: KeyCombo? = nil) {
        self.deck = deck
        self.expose = expose
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deck = c.value(.deck, default: nil)
        expose = c.value(.expose, default: nil)
    }
}

public struct DeckSettings: Codable, Sendable, Equatable {
    public static let contentPeekRange: ClosedRange<Double> = 0...120
    public static let maxStackDepthRange: ClosedRange<Int> = 1...8

    /// 后层卡片露出的窗口内容高度（不含标题区）。
    public var contentPeek: Double = 36
    public var maxStackDepth: Int = 5
    public var showAppsWithoutWindows: Bool = false
    /// 悬停牌堆后展开。
    public var expandOnHover: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeckSettings()
        contentPeek = min(max(c.value(.contentPeek, default: d.contentPeek), Self.contentPeekRange.lowerBound), Self.contentPeekRange.upperBound)
        maxStackDepth = min(max(c.value(.maxStackDepth, default: d.maxStackDepth), Self.maxStackDepthRange.lowerBound), Self.maxStackDepthRange.upperBound)
        showAppsWithoutWindows = c.value(.showAppsWithoutWindows, default: d.showAppsWithoutWindows)
        expandOnHover = c.value(.expandOnHover, default: d.expandOnHover)
    }
}

/// 浏览器标签页视图的分组方式。
public enum BrowserTabGrouping: String, Codable, Sendable, CaseIterable {
    case domain, window
}

public struct ExposeSettings: Codable, Sendable, Equatable {
    public var showMinimizedStrip: Bool = true
    public var groupOtherSpaces: Bool = false
    /// 当前应用是受支持的浏览器（Chrome）时，默认显示标签页而不是窗口（通过 Apple Events 读取，需要"自动化"权限）。
    public var showBrowserTabs: Bool = true
    /// 标签页视图中包含无痕窗口。
    public var includeIncognitoTabs: Bool = false
    public var tabGrouping: BrowserTabGrouping = .domain

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExposeSettings()
        showMinimizedStrip = c.value(.showMinimizedStrip, default: d.showMinimizedStrip)
        groupOtherSpaces = c.value(.groupOtherSpaces, default: d.groupOtherSpaces)
        showBrowserTabs = c.value(.showBrowserTabs, default: d.showBrowserTabs)
        includeIncognitoTabs = c.value(.includeIncognitoTabs, default: d.includeIncognitoTabs)
        tabGrouping = c.value(.tabGrouping, default: d.tabGrouping)
    }
}

public struct TrafficLightSettings: Codable, Sendable, Equatable {
    public var visibility: TrafficLightVisibility = .onHover
    public var showClose = true
    public var showMinimize = true
    public var showGreen = true
    public var greenAction: GreenAction = .fullscreen
    public var closeConfirmation: CloseConfirmation = .none

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrafficLightSettings()
        visibility = c.value(.visibility, default: d.visibility)
        showClose = c.value(.showClose, default: d.showClose)
        showMinimize = c.value(.showMinimize, default: d.showMinimize)
        showGreen = c.value(.showGreen, default: d.showGreen)
        greenAction = c.value(.greenAction, default: d.greenAction)
        closeConfirmation = c.value(.closeConfirmation, default: d.closeConfirmation)
    }
}

public struct AppearanceSettings: Codable, Sendable, Equatable {
    /// 遮罩透明度 0…0.9（深色外观下为暗色遮罩，浅色外观下为亮色遮罩）。
    public var dimOpacity: Double = 0.35
    public var reduceMotion: ReduceMotionMode = .system
    public var theme: AppTheme = .system
    public var overlayTheme: OverlayTheme = .followApp

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        dimOpacity = min(max(c.value(.dimOpacity, default: d.dimOpacity), 0), 0.9)
        reduceMotion = c.value(.reduceMotion, default: d.reduceMotion)
        theme = c.value(.theme, default: d.theme)
        overlayTheme = c.value(.overlayTheme, default: d.overlayTheme)
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = AppSettings.currentSchemaVersion

    // 触发
    public var gesture = GestureSettings()
    public var hotkeys = HotkeySettings()

    // 展示
    /// false = 仅标题模式（F5）。
    public var showThumbnails = true
    public var thumbnailQuality: ThumbnailQuality = .balanced
    public var titleStyle = TitleStyle()
    public var titleCleanup = TitleCleanup()
    public var deck = DeckSettings()
    public var expose = ExposeSettings()
    public var trafficLights = TrafficLightSettings()
    public var appearance = AppearanceSettings()

    // 过滤
    public var excludedBundleIDs: [String] = []
    public var showMinimized = true
    public var showHiddenApps = true
    public var showWindowsFromOtherSpaces = true
    /// `.accessory` 应用（例如菜单栏工具）有标准窗口时也纳入。
    public var includeAccessoryApps = true
    public var multiDisplay: MultiDisplayMode = .perScreen

    // 行为
    public var dismissAfterAction = false
    public var launchAtLogin = false
    /// 实验性：用私有 API 精确聚焦窗口。
    public var preciseFocus = true
    public var hasCompletedOnboarding = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schemaVersion = c.value(.schemaVersion, default: d.schemaVersion)
        gesture = c.value(.gesture, default: d.gesture)
        hotkeys = c.value(.hotkeys, default: d.hotkeys)
        showThumbnails = c.value(.showThumbnails, default: d.showThumbnails)
        thumbnailQuality = c.value(.thumbnailQuality, default: d.thumbnailQuality)
        titleStyle = c.value(.titleStyle, default: d.titleStyle)
        titleCleanup = c.value(.titleCleanup, default: d.titleCleanup)
        deck = c.value(.deck, default: d.deck)
        expose = c.value(.expose, default: d.expose)
        trafficLights = c.value(.trafficLights, default: d.trafficLights)
        appearance = c.value(.appearance, default: d.appearance)
        excludedBundleIDs = c.value(.excludedBundleIDs, default: d.excludedBundleIDs)
        showMinimized = c.value(.showMinimized, default: d.showMinimized)
        showHiddenApps = c.value(.showHiddenApps, default: d.showHiddenApps)
        showWindowsFromOtherSpaces = c.value(.showWindowsFromOtherSpaces, default: d.showWindowsFromOtherSpaces)
        includeAccessoryApps = c.value(.includeAccessoryApps, default: d.includeAccessoryApps)
        multiDisplay = c.value(.multiDisplay, default: d.multiDisplay)
        dismissAfterAction = c.value(.dismissAfterAction, default: d.dismissAfterAction)
        launchAtLogin = c.value(.launchAtLogin, default: d.launchAtLogin)
        preciseFocus = c.value(.preciseFocus, default: d.preciseFocus)
        hasCompletedOnboarding = c.value(.hasCompletedOnboarding, default: d.hasCompletedOnboarding)
    }
}

/// 配置的编解码与迁移。
public enum SettingsCodec {
    public static func encode(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    /// 解码并迁移到当前版本。数据完全无法解析时抛错，由调用方决定是否回退默认值。
    public static func decode(_ data: Data) throws -> AppSettings {
        var settings = try JSONDecoder().decode(AppSettings.self, from: data)
        settings = migrate(settings)
        return settings
    }

    static func migrate(_ settings: AppSettings) -> AppSettings {
        var s = settings
        // v1 是首个版本，暂无迁移步骤；新版本在此按 schemaVersion 逐级迁移。
        s.schemaVersion = AppSettings.currentSchemaVersion
        return s
    }
}
