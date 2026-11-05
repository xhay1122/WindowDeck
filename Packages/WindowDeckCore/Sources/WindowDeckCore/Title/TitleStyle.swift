import Foundation

public enum FontWeight: String, Codable, Sendable, CaseIterable {
    case regular, medium, semibold, bold
}

public enum Truncation: String, Codable, Sendable, CaseIterable {
    case head, middle, tail
}

public enum TitleBackground: String, Codable, Sendable, CaseIterable {
    case none, pill, bar
}

public struct TitleStyle: Codable, Sendable, Equatable {
    public static let fontSizeRange: ClosedRange<Double> = 11...40
    public static let maxLinesRange: ClosedRange<Int> = 1...3

    /// 范围 11–40。
    public var fontSize: Double = 15
    public var weight: FontWeight = .semibold
    /// 1–3。
    public var maxLines: Int = 2
    public var truncation: Truncation = .middle
    /// Exposé 视图中通常不需要。
    public var showAppNamePrefix: Bool = false
    public var background: TitleBackground = .pill

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TitleStyle()
        fontSize = c.value(.fontSize, default: d.fontSize)
        weight = c.value(.weight, default: d.weight)
        maxLines = c.value(.maxLines, default: d.maxLines)
        truncation = c.value(.truncation, default: d.truncation)
        showAppNamePrefix = c.value(.showAppNamePrefix, default: d.showAppNamePrefix)
        background = c.value(.background, default: d.background)
        self = normalized()
    }

    /// 把越界值夹回合法范围。
    public func normalized() -> TitleStyle {
        var s = self
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        s.maxLines = min(max(maxLines, Self.maxLinesRange.lowerBound), Self.maxLinesRange.upperBound)
        return s
    }

    /// 标题内边距（上下各一份）。
    public static let verticalPadding: Double = 6

    /// 估算标题区高度。App 层会用真实字体度量覆盖，这里用于单测和兜底。
    public func estimatedBandHeight(lineHeightFactor: Double = 1.22) -> Double {
        (fontSize * lineHeightFactor * Double(maxLines)).rounded(.up) + Self.verticalPadding * 2
    }
}

public struct TitleCleanup: Codable, Sendable, Equatable {
    /// 去掉 " — AppName" 一类后缀。
    public var stripAppSuffix: Bool = true
    /// 同一应用窗口标题的公共前后缀弱化显示。
    public var foldCommonAffix: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TitleCleanup()
        stripAppSuffix = c.value(.stripAppSuffix, default: d.stripAppSuffix)
        foldCommonAffix = c.value(.foldCommonAffix, default: d.foldCommonAffix)
    }
}
