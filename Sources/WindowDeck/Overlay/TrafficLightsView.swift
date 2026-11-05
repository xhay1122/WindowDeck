import AppKit
import WindowDeckCore

enum TrafficLightKind: Sendable {
    case close, minimize, green
}

/// 一个红绿灯按钮：自绘圆点，悬停时显示符号。
final class TrafficLightButton: NSView {
    let kind: TrafficLightKind
    var isEnabled = true { didSet { needsDisplay = true } }
    var showsSymbol = false { didSet { needsDisplay = true } }
    /// 关闭按钮"再点一次确认"状态。
    var isArmed = false { didSet { needsDisplay = true } }
    /// 黄灯在已收起的窗口上表示"恢复"。
    var isRestore = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    private var isPressed = false

    init(kind: TrafficLightKind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var baseColor: NSColor {
        guard isEnabled else { return NSColor(white: 0.55, alpha: 0.6) }
        switch kind {
        case .close: return NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1)
        case .minimize: return NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)
        case .green: return NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height) * 0.72
        let circle = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        var color = baseColor
        if isPressed { color = color.blended(withFraction: 0.25, of: .black) ?? color }
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
        ring.lineWidth = 0.5
        ring.stroke()

        guard (showsSymbol || isArmed), isEnabled else { return }
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = max(1, d * 0.11)
        path.lineCapStyle = .round
        let r = d * 0.24
        let c = NSPoint(x: circle.midX, y: circle.midY)
        switch kind {
        case .close where isArmed:
            // "?"：再点一次确认。
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: d * 0.7, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.7),
            ]
            let s = NSAttributedString(string: "?", attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
            return
        case .close:
            path.move(to: NSPoint(x: c.x - r, y: c.y - r)); path.line(to: NSPoint(x: c.x + r, y: c.y + r))
            path.move(to: NSPoint(x: c.x - r, y: c.y + r)); path.line(to: NSPoint(x: c.x + r, y: c.y - r))
        case .minimize where isRestore:
            path.move(to: NSPoint(x: c.x - r, y: c.y)); path.line(to: NSPoint(x: c.x + r, y: c.y))
            path.move(to: NSPoint(x: c.x, y: c.y - r)); path.line(to: NSPoint(x: c.x, y: c.y + r))
        case .minimize:
            path.move(to: NSPoint(x: c.x - r * 1.1, y: c.y)); path.line(to: NSPoint(x: c.x + r * 1.1, y: c.y))
        case .green:
            // 两个对角三角形，表示全屏 / 缩放。
            let t = r * 0.95
            let a = NSBezierPath()
            a.move(to: NSPoint(x: c.x - t, y: c.y + t * 0.2)); a.line(to: NSPoint(x: c.x - t, y: c.y - t)); a.line(to: NSPoint(x: c.x + t * 0.2, y: c.y - t)); a.close()
            a.move(to: NSPoint(x: c.x + t, y: c.y - t * 0.2)); a.line(to: NSPoint(x: c.x + t, y: c.y + t)); a.line(to: NSPoint(x: c.x - t * 0.2, y: c.y + t)); a.close()
            NSColor.black.withAlphaComponent(0.55).setFill()
            a.fill()
            return
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPress?()
        }
    }
}

/// 关闭 / 收起 / 绿灯三个按钮。
final class TrafficLightsView: NSView {
    let close = TrafficLightButton(kind: .close)
    let minimize = TrafficLightButton(kind: .minimize)
    let green = TrafficLightButton(kind: .green)

    var showsSymbols = false {
        didSet { [close, minimize, green].forEach { $0.showsSymbol = showsSymbols } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [close, minimize, green].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 根据按钮直径计算总宽度。
    static func width(buttonSize: CGFloat, visibleCount: Int) -> CGFloat {
        guard visibleCount > 0 else { return 0 }
        return buttonSize * CGFloat(visibleCount) + spacing(buttonSize) * CGFloat(visibleCount - 1)
    }

    static func spacing(_ size: CGFloat) -> CGFloat { max(2, size * 0.28) }

    /// 尺寸随卡片缩放，可点击区域限制在 16–22pt。
    static func buttonSize(forBand band: CGFloat) -> CGFloat {
        min(max(band * 0.5, 16), 22)
    }

    func layoutButtons(size: CGFloat, settings: TrafficLightSettings) {
        var x: CGFloat = 0
        let spacing = Self.spacing(size)
        for (button, visible) in [(close, settings.showClose), (minimize, settings.showMinimize), (green, settings.showGreen)] {
            button.isHidden = !visible
            guard visible else { continue }
            button.frame = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
            x += size + spacing
        }
    }
}
