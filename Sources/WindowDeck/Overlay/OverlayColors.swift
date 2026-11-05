import AppKit
import WindowDeckCore

/// 覆盖层配色：每个颜色都是随外观变化的动态颜色（深色 / 浅色两套）。
/// 文本颜色在绘制时自动解析；CALayer 属性需要用 `NSView.resolvedCGColor(_:)` 在视图的外观下解析，
/// 并在 `viewDidChangeEffectiveAppearance()` 中重新设置。
enum OverlayColors {
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        }
    }

    // MARK: 文本

    /// 主要文本，`alpha` 为不透明度。
    static func text(alpha: CGFloat = 1) -> NSColor {
        dynamic(dark: NSColor.white.withAlphaComponent(alpha), light: NSColor(white: 0.08, alpha: alpha))
    }

    /// 文字阴影 / 光晕：深色下为黑色阴影，浅色下为白色光晕，保证压在缩略图上时可读。
    static var textShadow: NSColor {
        dynamic(dark: NSColor.black.withAlphaComponent(0.6), light: NSColor.white.withAlphaComponent(0.7))
    }

    // MARK: 背景

    /// 背景遮罩（`dimOpacity` 作用在这层上）。
    /// 浅色下用中灰而不是白色：窗口缩略图大多是白底，背景再被提亮会和卡片糊在一起。
    static var dim: NSColor { dynamic(dark: .black, light: NSColor(white: 0.35, alpha: 1)) }

    /// 牌堆卡片底色。
    static var cardBackground: NSColor { dynamic(dark: NSColor(white: 0.17, alpha: 1), light: NSColor(white: 0.97, alpha: 1)) }

    /// 牌堆卡片"整条"标题背景。
    static var cardBar: NSColor { dynamic(dark: NSColor(white: 0.26, alpha: 1), light: NSColor(white: 0.88, alpha: 1)) }

    /// 缩略图缺失时的底色。
    static var thumbnailPlaceholder: NSColor { dynamic(dark: NSColor(white: 0.22, alpha: 1), light: NSColor(white: 0.86, alpha: 1)) }

    /// 牌堆卡片上的标题胶囊。
    static var deckPill: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.08), light: NSColor.black.withAlphaComponent(0.06)) }

    /// 浮在背景上的标题胶囊（当前应用视图）。
    static var floatingPill: NSColor { dynamic(dark: NSColor.black.withAlphaComponent(0.55), light: NSColor.white.withAlphaComponent(0.75)) }

    /// 浮在背景上的"整条"标题背景（当前应用视图）。
    static var floatingBar: NSColor { dynamic(dark: NSColor.black.withAlphaComponent(0.5), light: NSColor.white.withAlphaComponent(0.7)) }

    /// 卡片边框：选中用强调色，悬停 / 常态用这里的颜色。
    static var hoverBorder: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.55), light: NSColor.black.withAlphaComponent(0.35)) }
    static var idleBorder: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.14), light: NSColor.black.withAlphaComponent(0.2)) }

    /// 仅标题模式一行的选中 / 悬停底色。
    static var rowSelected: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.16), light: NSColor.black.withAlphaComponent(0.1)) }
    static var rowHovered: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.08), light: NSColor.black.withAlphaComponent(0.05)) }

    /// 角标（已收起 / 其他桌面 / +N 等）。
    static var badgeBackground: NSColor { dynamic(dark: NSColor.black.withAlphaComponent(0.62), light: NSColor.white.withAlphaComponent(0.85)) }

    /// 面板（仅标题模式的应用分组、展开牌堆的背板），`alpha` 为不透明度。
    static func panel(alpha: CGFloat) -> NSColor {
        dynamic(dark: NSColor(white: 0.08, alpha: alpha), light: NSColor(white: 0.98, alpha: alpha))
    }

    static var panelBorder: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.12), light: NSColor.black.withAlphaComponent(0.1)) }

    /// 没有窗口的应用图标牌。
    static var tileBackground: NSColor { dynamic(dark: NSColor(white: 0.12, alpha: 0.7), light: NSColor(white: 0.96, alpha: 0.7)) }
    static var tileBorder: NSColor { dynamic(dark: NSColor.white.withAlphaComponent(0.15), light: NSColor.black.withAlphaComponent(0.1)) }

    /// 浮层（完整标题、提示）背景。
    static var popupBackground: NSColor { dynamic(dark: NSColor.black.withAlphaComponent(0.7), light: NSColor.white.withAlphaComponent(0.9)) }

    /// 小图标按钮的底色，`alpha` 为不透明度。
    static func iconButton(alpha: CGFloat) -> NSColor {
        dynamic(dark: NSColor.white.withAlphaComponent(alpha), light: NSColor.black.withAlphaComponent(alpha * 0.6))
    }

    /// 覆盖层文字阴影。阴影在图层上是静态 CGColor，外观变化后需要重新生成。
    @MainActor
    static func shadow(for view: NSView) -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor(cgColor: view.resolvedCGColor(textShadow))
        s.shadowBlurRadius = 3
        s.shadowOffset = .zero
        return s
    }
}

extension NSAppearance {
    /// 高对比度、vibrant 等变体也会被 bestMatch 归到深色 / 浅色之一。
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension AppTheme {
    /// nil 表示跟随系统。
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension OverlayTheme {
    /// nil 表示继承 NSApp.appearance（即应用主题）。
    var appearance: NSAppearance? {
        switch self {
        case .followApp: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension NSView {
    /// 按视图当前的有效外观把动态颜色解析成 CGColor（CALayer 属性不会自动跟随外观变化）。
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}
