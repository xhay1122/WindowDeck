import AppKit
import WindowDeckCore

enum CardStyle: Sendable {
    /// Deck 视图：标题区在上，缩略图在下（后层卡片露出标题 + 部分内容）。
    case deck
    /// Exposé 视图：缩略图在上，标题在下。
    case expose
    /// 仅标题模式的一行。
    case row
}

enum CardAction: Sendable {
    case focus
    case close
    case toggleMinimize
    case green
    case hint(String)
}

/// 缩略图：Deck 卡片按顶部对齐裁剪，露出窗口顶部（通常是窗口自己的标题栏和开头内容）。
final class ThumbnailView: NSView {
    var topAligned = true { didSet { needsLayout = true } }
    private var image: CGImage?
    private var croppedForAspect: CGFloat = 0
    private let iconLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        // 截图通常大于卡片显示尺寸，三线性过滤缩小时文字更清晰、不发虚。
        layer?.minificationFilter = .trilinear
        layer?.backgroundColor = resolvedCGColor(OverlayColors.thumbnailPlaceholder)
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(OverlayColors.thumbnailPlaceholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // 手动布局：尺寸变化时需要重新布局（不使用 Auto Layout 时 AppKit 不会自动标记）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override var wantsUpdateLayer: Bool { true }

    var hasImage: Bool { image != nil }

    func set(image: CGImage?, icon: NSImage?, animated: Bool) {
        if animated, layer?.contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            layer?.add(fade, forKey: "contents")
        }
        self.image = image
        croppedForAspect = 0
        iconLayer.contents = image == nil ? icon : nil
        iconLayer.isHidden = image != nil
        if image == nil { layer?.contents = nil }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = min(min(bounds.width, bounds.height) * 0.45, 72)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        CATransaction.commit()

        guard let image, bounds.width > 1, bounds.height > 1 else { return }
        let aspect = bounds.width / bounds.height
        guard abs(aspect - croppedForAspect) > 0.01 else { return }
        croppedForAspect = aspect
        layer?.contents = topAligned ? Self.crop(image, toAspect: aspect) : image
        layer?.contentsGravity = topAligned ? .resizeAspectFill : .resizeAspect
    }

    static func crop(_ image: CGImage, toAspect aspect: CGFloat) -> CGImage {
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return image }
        let imageAspect = iw / ih
        if abs(imageAspect - aspect) < 0.01 { return image }
        if imageAspect > aspect {
            let w = (ih * aspect).rounded()
            return image.cropping(to: CGRect(x: ((iw - w) / 2).rounded(), y: 0, width: w, height: ih)) ?? image
        }
        let h = (iw / aspect).rounded()
        return image.cropping(to: CGRect(x: 0, y: 0, width: iw, height: h)) ?? image
    }
}

/// 小角标：已收起 / 其他桌面 / 全屏 / 已隐藏 / 未响应。
final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = resolvedCGColor(OverlayColors.badgeBackground)
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = OverlayColors.text()
        label.stringValue = text
        addSubview(label)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(OverlayColors.badgeBackground)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // 手动布局：尺寸变化时需要重新布局（不使用 Auto Layout 时 AppKit 不会自动标记）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    var fittingWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 12 }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 6, y: (bounds.height - size.height) / 2, width: bounds.width - 12, height: size.height)
    }
}

/// 一张窗口卡片。
final class CardView: NSView {
    let windowID: CGWindowID
    private(set) var windowInfo: WindowInfo
    private(set) var app: AppInfo
    private(set) var style: CardStyle
    private var title: FormattedTitle
    private var settings: AppSettings

    var onAction: ((CardAction) -> Void)?
    /// 布局层（Deck 中的 depth）等附加信息由覆盖层维护。
    var deckDepth = 0
    var isOverflow = false

    private let thumbnail = ThumbnailView()
    private let band = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let lights = TrafficLightsView()
    private var badges: [BadgeView] = []
    private(set) var isTitleTruncated = false
    private var closeArmedUntil: Date?

    var isHovered = false { didSet { if isHovered != oldValue { updateState() } } }
    var isSelected = false { didSet { if isSelected != oldValue { updateState() } } }

    init(window: WindowInfo, app: AppInfo, title: FormattedTitle, style: CardStyle, settings: AppSettings) {
        self.windowID = window.id
        self.windowInfo = window
        self.app = app
        self.title = title
        self.style = style
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style == .row ? 8 : 10
        layer?.masksToBounds = false

        band.wantsLayer = true
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        titleLabel.isBordered = false
        titleLabel.cell?.wraps = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.wantsLayer = true
        titleLabel.shadow = OverlayColors.shadow(for: self)

        if style != .row { addSubview(thumbnail) }
        addSubview(band)
        band.addSubview(titleLabel)
        addSubview(lights)

        lights.close.onPress = { [weak self] in self?.pressClose() }
        lights.minimize.onPress = { [weak self] in self?.onAction?(.toggleMinimize) }
        lights.green.onPress = { [weak self] in self?.onAction?(.green) }

        update(window: window, app: app, title: title, style: style, settings: settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // 手动布局：尺寸变化时需要重新布局（不使用 Auto Layout 时 AppKit 不会自动标记）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 图层颜色是静态 CGColor，外观变化（例如加入覆盖层窗口、系统切换深浅色）后重新设置。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        titleLabel.shadow = OverlayColors.shadow(for: self)
        needsLayout = true
        updateState()
    }

    func update(window: WindowInfo, app: AppInfo, title: FormattedTitle, style: CardStyle, settings: AppSettings) {
        self.windowInfo = window
        self.app = app
        self.title = title
        self.settings = settings
        if style != self.style {
            self.style = style
            if style == .row { thumbnail.removeFromSuperview() } else if thumbnail.superview == nil { addSubview(thumbnail, positioned: .below, relativeTo: band) }
        }
        thumbnail.topAligned = style == .deck

        let caps = window.capabilities
        lights.close.isEnabled = caps.contains(.close)
        lights.minimize.isEnabled = caps.contains(.minimize) || window.isMinimized
        lights.minimize.isRestore = window.isMinimized
        let green = settings.trafficLights.greenAction == .fullscreen ? caps.contains(.fullscreen) || caps.contains(.zoom) : caps.contains(.zoom)
        lights.green.isEnabled = green && !window.isMinimized

        var badgeTexts: [String] = []
        if app.isUnresponsive { badgeTexts.append(String(localized: "未响应")) }
        if app.isHidden { badgeTexts.append(String(localized: "已隐藏")) }
        if window.isMinimized { badgeTexts.append(String(localized: "已收起")) }
        if !window.isOnCurrentSpace { badgeTexts.append(window.isFullscreen ? String(localized: "全屏") : String(localized: "其他桌面")) }
        else if window.isFullscreen { badgeTexts.append(String(localized: "全屏")) }
        if badgeTexts != badges.map({ $0.accessibilityLabel() ?? "" }) {
            badges.forEach { $0.removeFromSuperview() }
            badges = badgeTexts.map { text in
                let b = BadgeView(text: text)
                b.setAccessibilityLabel(text)
                return b
            }
            badges.forEach(addSubview)
        }

        // 隐藏应用的窗口半透明显示。
        thumbnail.alphaValue = app.isHidden ? 0.55 : 1
        needsLayout = true
        updateState()
    }

    func setThumbnail(_ image: CGImage?, animated: Bool) {
        let icon = image == nil ? NSRunningApplication(processIdentifier: app.pid)?.icon : nil
        thumbnail.set(image: image, icon: icon, animated: animated)
    }

    var hasThumbnail: Bool { thumbnail.hasImage }

    var fullTitle: String { title.full }

    /// 标题区在卡片内的位置（用于完整标题浮层定位）。
    var titleBandFrame: NSRect { band.frame }

    // MARK: 布局

    private var bandHeight: CGFloat { TitleRenderer.bandHeight(for: settings.titleStyle) }

    private var lightsVisibleCount: Int {
        let t = settings.trafficLights
        return [t.showClose, t.showMinimize, t.showGreen].filter { $0 }.count
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let b = bounds
        let bandH = min(bandHeight, b.height)
        let lightSize = TrafficLightsView.buttonSize(forBand: min(bandH, 44))
        let lightsW = settings.trafficLights.visibility == .never ? 0 : TrafficLightsView.width(buttonSize: lightSize, visibleCount: lightsVisibleCount)
        let pad = TitleRenderer.horizontalPadding
        // 悬停才显示时红绿灯浮在标题上，标题不再预留位置。
        let reservesLights = lightsW > 0 && !lightsOverlayTitle

        switch style {
        case .deck, .expose:
            // 标题栏统一在顶部（与真实窗口一致）：红绿灯在左，标题紧随其后，缩略图在下。
            band.frame = NSRect(x: 0, y: 0, width: b.width, height: bandH)
            thumbnail.frame = NSRect(x: 0, y: bandH, width: b.width, height: max(0, b.height - bandH))
            lights.frame = NSRect(x: pad + 2, y: 0, width: lightsW, height: min(bandH, lightSize + 12))
            lights.frame.origin.y = (min(bandH, CGFloat(TitleStyle.verticalPadding) * 2 + TitleRenderer.lineHeight(for: settings.titleStyle)) - lights.frame.height) / 2
            let inset: CGFloat = reservesLights ? lightsW + 10 : 0
            layoutTitle(in: NSRect(x: pad + inset, y: 0, width: b.width - pad * 2 - inset, height: bandH), alignment: .left)
        case .row:
            band.frame = b
            lights.frame = NSRect(x: pad + 4, y: 0, width: lightsW, height: b.height)
            let inset: CGFloat = reservesLights ? lightsW + 12 : 0
            layoutTitle(in: NSRect(x: pad + 4 + inset, y: 0, width: b.width - pad * 2 - 8 - inset - badgesWidth, height: b.height), alignment: .left)
        }
        lights.layoutButtons(size: lightSize, settings: settings.trafficLights)
        layoutBadges()
        styleLayers()
    }

    /// 红绿灯是否浮在标题上（而不是在标题左侧占位）。
    private var lightsOverlayTitle: Bool { settings.trafficLights.visibility == .onHover }

    private var badgesWidth: CGFloat {
        badges.reduce(0) { $0 + $1.fittingWidth + 6 }
    }

    private func layoutTitle(in rect: NSRect, alignment: NSTextAlignment) {
        let style = settings.titleStyle
        let prefix = style.showAppNamePrefix ? app.name : nil
        let result = TitleRenderer.render(title, appPrefix: prefix, style: style, width: rect.width - 4, alignment: alignment)
        isTitleTruncated = result.isTruncated
        titleLabel.attributedStringValue = result.text
        titleLabel.maximumNumberOfLines = style.maxLines
        let fitted = result.text.boundingRect(with: CGSize(width: rect.width - 4, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let h = min(ceil(fitted.height) + 2, rect.height)
        var w = min(ceil(fitted.width) + 6, rect.width)
        if style.background == .bar || self.style == .row { w = rect.width }
        let x = alignment == .center ? rect.midX - w / 2 : rect.minX
        let frameInBand = NSRect(x: x - band.frame.minX, y: rect.minY - band.frame.minY + (rect.height - h) / 2, width: w, height: h)
        titleLabel.frame = frameInBand
    }

    private func layoutBadges() {
        var x: CGFloat
        let h: CGFloat = 20
        switch style {
        case .row:
            x = bounds.width - TitleRenderer.horizontalPadding
            for badge in badges.reversed() {
                let w = badge.fittingWidth
                x -= w
                badge.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
                x -= 6
            }
        case .deck, .expose:
            let top = thumbnail.frame.minY + 8
            x = bounds.width - 8
            for badge in badges.reversed() {
                let w = badge.fittingWidth
                x -= w
                badge.frame = NSRect(x: x, y: top, width: w, height: h)
                x -= 6
            }
        }
    }

    private func styleLayers() {
        let bg = settings.titleStyle.background
        switch style {
        case .deck:
            layer?.backgroundColor = resolvedCGColor(OverlayColors.cardBackground)
            layer?.masksToBounds = true
            band.layer?.backgroundColor = resolvedCGColor(bg == .bar ? OverlayColors.cardBar : OverlayColors.cardBackground)
            band.layer?.cornerRadius = 0
            thumbnail.layer?.cornerRadius = 0
        case .expose:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.masksToBounds = false
            thumbnail.layer?.cornerRadius = 10
            band.layer?.backgroundColor = NSColor.clear.cgColor
        case .row:
            layer?.masksToBounds = true
            band.layer?.backgroundColor = NSColor.clear.cgColor
        }
        // 标题背景：pill = 标题文字下的胶囊；bar = 整条；none = 只有阴影。
        titleLabel.layer?.cornerRadius = bg == .pill ? min(10, titleLabel.frame.height / 2) : 0
        let pillColor = style == .deck ? OverlayColors.deckPill : OverlayColors.floatingPill
        titleLabel.layer?.backgroundColor = (bg == .pill && style != .row) ? resolvedCGColor(pillColor) : NSColor.clear.cgColor
        if bg == .bar, style == .expose {
            band.layer?.backgroundColor = resolvedCGColor(OverlayColors.floatingBar)
            band.layer?.cornerRadius = 8
        }
    }

    private func updateState() {
        let visibility = settings.trafficLights.visibility
        // 悬停模式下红绿灯会盖住标题，只在鼠标悬停时出现；键盘切换选中时保持标题完整可读。
        lights.isHidden = visibility == .never || (visibility == .onHover && !isHovered)
        lights.showsSymbols = isHovered
        if !isHovered, closeArmedUntil != nil {
            closeArmedUntil = nil
            lights.close.isArmed = false
        }

        let target: CALayer? = style == .expose ? thumbnail.layer : layer
        let other: CALayer? = style == .expose ? layer : nil
        other?.borderWidth = 0
        if isSelected {
            target?.borderWidth = 3
            target?.borderColor = resolvedCGColor(.controlAccentColor)
        } else if isHovered {
            target?.borderWidth = 2
            target?.borderColor = resolvedCGColor(OverlayColors.hoverBorder)
        } else {
            target?.borderWidth = style == .deck ? 0.5 : 0
            target?.borderColor = resolvedCGColor(OverlayColors.idleBorder)
        }
        if style == .row {
            layer?.backgroundColor = resolvedCGColor(isSelected ? OverlayColors.rowSelected : isHovered ? OverlayColors.rowHovered : .clear)
        }
    }

    // MARK: 交互

    private func pressClose() {
        switch settings.trafficLights.closeConfirmation {
        case .none:
            onAction?(.close)
        case .optionKey:
            if NSEvent.modifierFlags.contains(.option) {
                onAction?(.close)
            } else {
                shake()
                onAction?(.hint(String(localized: "按住 ⌥ Option 再点关闭")))
            }
        case .clickTwice:
            if let until = closeArmedUntil, until > Date() {
                closeArmedUntil = nil
                lights.close.isArmed = false
                onAction?(.close)
            } else {
                closeArmedUntil = Date().addingTimeInterval(2)
                lights.close.isArmed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let until = self.closeArmedUntil, until <= Date() else { return }
                        self.closeArmedUntil = nil
                        self.lights.close.isArmed = false
                    }
                }
            }
        }
    }

    func shake() {
        guard let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -8, 8, -5, 5, 0].map { layer.position.x + $0 }
        animation.duration = 0.32
        layer.add(animation, forKey: "shake")
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onAction?(.focus)
        }
    }
}
