import AppKit
import WindowDeckCore

/// 一个小号的图标按钮（用 SF Symbol）。
final class IconButton: NSView {
    var onPress: (() -> Void)?
    private let imageView = NSImageView()
    private var isPressed = false { didSet { updateColors() } }
    var isHighlighted = false { didSet { updateColors() } }

    init(symbol: String, tooltip: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        imageView.contentTintColor = OverlayColors.text()
        imageView.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        addSubview(imageView)
        setAccessibilityLabel(tooltip)
        updateColors()
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func setSymbol(_ symbol: String) {
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    private func updateColors() {
        let alpha: CGFloat = isPressed ? 0.35 : isHighlighted ? 0.5 : 0.18
        layer?.backgroundColor = resolvedCGColor(isHighlighted ? NSColor.systemRed.withAlphaComponent(alpha) : OverlayColors.iconButton(alpha: alpha))
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}

/// 牌堆下方的应用标题行：图标 + 应用名 · N 个窗口，悬停时显示"隐藏 / 退出"。
final class AppHeaderView: NSView {
    let pid: pid_t
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hideButton = IconButton(symbol: "eye.slash", tooltip: String(localized: "隐藏应用"))
    private let quitButton = IconButton(symbol: "power", tooltip: String(localized: "退出应用"))
    private var quitArmedUntil: Date?
    private var alignment: NSTextAlignment = .center

    var isHovered = false {
        didSet {
            hideButton.isHidden = !isHovered
            quitButton.isHidden = !isHovered
            if !isHovered { disarmQuit() }
        }
    }

    init(app: AppInfo, windowCount: Int, alignment: NSTextAlignment) {
        self.pid = app.pid
        super.init(frame: .zero)
        self.alignment = alignment
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSRunningApplication(processIdentifier: app.pid)?.icon
        label.textColor = OverlayColors.text()
        label.lineBreakMode = .byTruncatingTail
        label.shadow = OverlayColors.shadow(for: self)
        [iconView, label, hideButton, quitButton].forEach(addSubview)
        hideButton.onPress = { [weak self] in self?.onHide?() }
        quitButton.onPress = { [weak self] in self?.pressQuit() }
        update(app: app, windowCount: windowCount)
        // 属性观察器在 init 中不会触发，这里显式隐藏悬停按钮。
        hideButton.isHidden = true
        quitButton.isHidden = true
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.shadow = OverlayColors.shadow(for: self)
    }

    func update(app: AppInfo, windowCount: Int) {
        let name = NSAttributedString(string: app.name, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: OverlayColors.text()])
        let s = NSMutableAttributedString(attributedString: name)
        if windowCount > 1 {
            s.append(NSAttributedString(string: "  ·  " + String(localized: "\(windowCount) 个窗口"), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: OverlayColors.text(alpha: 0.65)]))
        }
        label.attributedStringValue = s
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let icon: CGFloat = min(22, bounds.height - 4)
        let buttons: CGFloat = 2 * 24 + 6
        let textWidth = max(0, min(ceil(label.attributedStringValue.size().width) + 6, bounds.width - icon - 8 - buttons - 8))
        let total = icon + 8 + textWidth
        let x0 = alignment == .center ? (bounds.width - total) / 2 : 0
        iconView.frame = NSRect(x: x0, y: (bounds.height - icon) / 2, width: icon, height: icon)
        let textH = label.intrinsicContentSize.height
        label.frame = NSRect(x: x0 + icon + 8, y: (bounds.height - textH) / 2, width: textWidth, height: textH)
        var bx = label.frame.maxX + 8
        for button in [hideButton, quitButton] {
            button.frame = NSRect(x: bx, y: (bounds.height - 22) / 2, width: 24, height: 22)
            bx += 30
        }
    }

    private func pressQuit() {
        if let until = quitArmedUntil, until > Date() {
            disarmQuit()
            onQuit?()
        } else {
            quitArmedUntil = Date().addingTimeInterval(2.5)
            quitButton.isHighlighted = true
            quitButton.setAccessibilityLabel(String(localized: "再点一次退出"))
        }
    }

    private func disarmQuit() {
        quitArmedUntil = nil
        quitButton.isHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// 圆角深色面板（仅标题模式的应用分组、展开牌堆的背板）。
final class PanelBackgroundView: NSView {
    private let fillAlpha: CGFloat

    init(cornerRadius: CGFloat = 14, alpha: CGFloat = 0.5) {
        fillAlpha = alpha
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 0.5
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(OverlayColors.panel(alpha: fillAlpha))
        layer?.borderColor = resolvedCGColor(OverlayColors.panelBorder)
    }
}

/// 文本标签（分组标题、空状态、提示、"+N"）。
final class OverlayLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let hasBackground: Bool

    init(text: String, size: CGFloat, weight: NSFont.Weight = .semibold, alpha: CGFloat = 0.8, background: Bool = false) {
        self.hasBackground = background
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = OverlayColors.text(alpha: alpha)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        if background {
            layer?.backgroundColor = resolvedCGColor(OverlayColors.popupBackground)
            layer?.cornerRadius = 10
        }
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if hasBackground { layer?.backgroundColor = resolvedCGColor(OverlayColors.popupBackground) }
    }

    // 手动布局：尺寸变化时需要重新布局（不使用 Auto Layout 时 AppKit 不会自动标记）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let pad: CGFloat = hasBackground ? 12 : 0
        label.preferredMaxLayoutWidth = maxWidth - pad * 2
        let size = label.sizeThatFits(NSSize(width: maxWidth - pad * 2, height: .greatestFiniteMagnitude))
        return CGSize(width: ceil(size.width) + pad * 2, height: ceil(size.height) + (hasBackground ? 12 : 0))
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = hasBackground ? 12 : 0
        let size = label.sizeThatFits(NSSize(width: bounds.width - pad * 2, height: .greatestFiniteMagnitude))
        label.frame = NSRect(x: pad, y: (bounds.height - size.height) / 2, width: bounds.width - pad * 2, height: ceil(size.height))
    }
}
