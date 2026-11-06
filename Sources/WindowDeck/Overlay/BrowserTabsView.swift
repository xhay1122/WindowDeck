import AppKit
import WindowDeckCore

/// 标签页在视图中的唯一键（窗口 id + 标签 id）。
struct BrowserTabKey: Hashable {
    var window: ScriptObjectID
    var tab: ScriptObjectID
}

/// Exposé 中浏览器的标签页视图：按域名或按窗口分组，每组一个面板（头部 + 标签页列表），多列瀑布流排布。
/// 视图铺满画布（与画布同坐标系），自己处理行的悬停、选中与点击；空白处点击交给 `onBackgroundClick`。
final class BrowserTabsView: NSView {
    /// 布局输入：一个分组。
    struct GroupInput {
        var id: String
        var symbol: String
        var title: String
        /// 角标：无痕 / 已收起 / 其他桌面。
        var badges: [String]
        /// 点击头部时切换到的标签页（按窗口分组时为该窗口的当前标签页）；nil 表示头部不可点。
        var headerTarget: (tab: BrowserTab, window: BrowserWindowTabs)?
        var rows: [RowInput]
    }

    struct RowInput {
        var tab: BrowserTab
        var window: BrowserWindowTabs
        var isActive: Bool
        /// 右侧说明：域名；按域名分组且有多个窗口时附带"窗口 N"。
        var detail: String
    }

    struct Group {
        var input: GroupInput
        var frame: CGRect
        var headerFrame: CGRect
        var rowFrames: [CGRect]
    }

    struct Message {
        var text: String
        var buttonTitle: String?
        var frame: CGRect
    }

    struct Content {
        var groups: [Group] = []
        var message: Message?
        var style: TitleStyle
    }

    var onActivate: ((BrowserTab, BrowserWindowTabs) -> Void)?
    var onClose: ((BrowserTab, BrowserWindowTabs) -> Void)?
    var onMessageAction: (() -> Void)?
    var onBackgroundClick: (() -> Void)?

    private var panels: [PanelBackgroundView] = []
    private var groupHeaders: [String: TabGroupHeaderView] = [:]
    private var rows: [BrowserTabKey: TabRowView] = [:]
    private var messageLabel: OverlayLabel?
    private var messageButton: PillButton?
    private var tracking: NSTrackingArea?
    /// 按布局顺序（组内自上而下）。
    private var orderedKeys: [BrowserTabKey] = []
    private var content: Content?

    private(set) var selectedKey: BrowserTabKey?
    private var hoveredKey: BrowserTabKey?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 布局

    /// 计算布局：复用"仅标题"模式的瀑布流算法（组 = 分组，行 = 标签页，id 只是序号）。
    static func layout(groups: [GroupInput], bounds: CGRect, style: TitleStyle) -> (groups: [Group], contentHeight: CGFloat) {
        var rowStyle = style
        rowStyle.maxLines = 1
        let rowHeight = max(TitleRenderer.lineHeight(for: rowStyle) + 12, 30)
        var next: CGWindowID = 0
        let inputs = groups.enumerated().map { index, group -> TitleListGroup in
            let ids = group.rows.map { _ -> CGWindowID in
                defer { next += 1 }
                return next
            }
            return TitleListGroup(appID: pid_t(index), windowIDs: ids)
        }
        let result = TitleListLayout.compute(TitleListLayoutInput(
            groups: inputs,
            bounds: bounds,
            rowHeight: rowHeight,
            headerHeight: 40,
            minColumnWidth: 340,
            maxColumnWidth: 640
        ))
        let placed = zip(inputs, result.groups).map { input, frame -> Group in
            let rowFrames = input.windowIDs.map { (frame.rows[$0] ?? .zero).insetBy(dx: 6, dy: 2) }
            return Group(input: groups[Int(input.appID)], frame: frame.frame, headerFrame: frame.headerFrame.insetBy(dx: 14, dy: 0), rowFrames: rowFrames)
        }
        return (placed, result.needsScrolling ? result.contentSize.height : bounds.height)
    }

    // MARK: 应用内容

    func apply(_ content: Content) {
        self.content = content

        panels.forEach { $0.removeFromSuperview() }
        panels = content.groups.map { group in
            let panel = PanelBackgroundView()
            panel.frame = group.frame
            addSubview(panel)
            return panel
        }

        var seenHeaders = Set<String>()
        var seenRows = Set<BrowserTabKey>()
        orderedKeys = []
        for group in content.groups {
            let input = group.input
            seenHeaders.insert(input.id)
            let header = groupHeaders[input.id] ?? TabGroupHeaderView()
            header.update(symbol: input.symbol, title: input.title, tabCount: input.rows.count, badges: input.badges)
            if let target = input.headerTarget {
                header.onClick = { [weak self] in self?.onActivate?(target.tab, target.window) }
            } else {
                header.onClick = nil
            }
            header.frame = group.headerFrame
            groupHeaders[input.id] = header
            addSubview(header)

            for (item, frame) in zip(input.rows, group.rowFrames) {
                let key = BrowserTabKey(window: item.window.id, tab: item.tab.id)
                seenRows.insert(key)
                orderedKeys.append(key)
                let row = rows[key] ?? TabRowView(key: key)
                row.update(tab: item.tab, detail: item.detail, isActive: item.isActive, style: content.style)
                let tab = item.tab
                let window = item.window
                row.onClick = { [weak self] in self?.onActivate?(tab, window) }
                row.onClose = { [weak self] in self?.onClose?(tab, window) }
                row.frame = frame
                rows[key] = row
                addSubview(row)
            }
        }
        for (id, header) in groupHeaders where !seenHeaders.contains(id) {
            header.removeFromSuperview()
            groupHeaders[id] = nil
        }
        for (key, row) in rows where !seenRows.contains(key) {
            row.removeFromSuperview()
            rows[key] = nil
        }
        if let key = selectedKey, rows[key] == nil { selectedKey = nil }
        if let key = hoveredKey, rows[key] == nil { hoveredKey = nil }
        for (key, row) in rows {
            row.isSelected = key == selectedKey
            row.isHovered = key == hoveredKey
        }

        messageLabel?.removeFromSuperview()
        messageButton?.removeFromSuperview()
        messageLabel = nil
        messageButton = nil
        if let message = content.message {
            let label = OverlayLabel(text: message.text, size: 18, weight: .medium, alpha: 0.8)
            let size = label.fittingSize(maxWidth: min(message.frame.width, 620))
            label.frame = CGRect(x: message.frame.midX - size.width / 2, y: message.frame.midY - size.height - 6, width: size.width, height: size.height)
            addSubview(label)
            messageLabel = label
            if let title = message.buttonTitle {
                let button = PillButton(title: title)
                let width = button.fittingWidth
                button.frame = CGRect(x: message.frame.midX - width / 2, y: label.frame.maxY + 14, width: width, height: 32)
                button.onPress = { [weak self] in self?.onMessageAction?() }
                addSubview(button)
                messageButton = button
            }
        }
    }

    // MARK: 悬停与选择

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var view = hitTest(point)
        var key: BrowserTabKey?
        while let v = view, v !== self {
            if let row = v as? TabRowView {
                key = row.key
                break
            }
            view = v.superview
        }
        setHovered(key)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ key: BrowserTabKey?) {
        guard key != hoveredKey else { return }
        if let old = hoveredKey { rows[old]?.isHovered = false }
        hoveredKey = key
        if let key {
            rows[key]?.isHovered = true
            select(key, scroll: false)
        }
    }

    private func select(_ key: BrowserTabKey?, scroll: Bool) {
        guard key != selectedKey else { return }
        if let old = selectedKey { rows[old]?.isSelected = false }
        selectedKey = key
        guard let key, let row = rows[key] else { return }
        row.isSelected = true
        if scroll { row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -24)) }
    }

    /// 没有选中项时的默认项：第一个"当前标签页"（按窗口分组时即最前窗口的当前标签页）。
    private var defaultKey: BrowserTabKey? {
        for group in content?.groups ?? [] {
            if let row = group.input.rows.first(where: \.isActive) {
                return BrowserTabKey(window: row.window.id, tab: row.tab.id)
            }
        }
        return orderedKeys.first
    }

    func navigate(_ direction: NavigationDirection) {
        guard selectedKey != nil else {
            select(defaultKey, scroll: true)
            return
        }
        let targets = orderedKeys.compactMap { key in rows[key].map { (id: key, rect: $0.frame) } }
        select(SpatialNavigation.next(from: selectedKey, direction: direction, targets: targets), scroll: true)
    }

    private func lookup(_ key: BrowserTabKey?) -> RowInput? {
        guard let key else { return nil }
        for group in content?.groups ?? [] {
            if let row = group.input.rows.first(where: { $0.window.id == key.window && $0.tab.id == key.tab }) { return row }
        }
        return nil
    }

    /// Return：切换到选中的标签页（没有选中时为默认项）。
    func activateSelection() {
        guard let row = lookup(selectedKey ?? defaultKey) else { return }
        onActivate?(row.tab, row.window)
    }

    /// ⌘W：关闭选中的标签页。
    func closeSelection() {
        guard let key = selectedKey, let row = lookup(key) else { return }
        rows[key]?.markClosing()
        onClose?(row.tab, row.window)
    }

    var hasContent: Bool { !orderedKeys.isEmpty }

    // MARK: 空白处点击

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 面板内部的空白不收起，避免误触。
        guard !panels.contains(where: { $0.frame.contains(point) }) else { return }
        onBackgroundClick?()
    }
}

/// 分组头部：图标 + 标题 · N 个标签页 + 角标。可点击时切换到该组的目标标签页。
final class TabGroupHeaderView: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        iconView.contentTintColor = OverlayColors.text(alpha: 0.8)
        label.lineBreakMode = .byTruncatingTail
        [iconView, label].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func update(symbol: String, title: String, tabCount: Int, badges: [String]) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: OverlayColors.text()])
        s.append(NSAttributedString(string: "  ·  " + String(localized: "\(tabCount) 个标签页"), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: OverlayColors.text(alpha: 0.65)]))
        for badge in badges {
            s.append(NSAttributedString(string: "   " + badge, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: OverlayColors.text(alpha: 0.55)]))
        }
        label.attributedStringValue = s
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let icon: CGFloat = 20
        iconView.frame = NSRect(x: 0, y: (bounds.height - icon) / 2, width: icon, height: icon)
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: icon + 8, y: (bounds.height - h) / 2, width: max(0, bounds.width - icon - 8), height: h)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// 一个标签页行：当前标签标记 + 标题 + 说明（域名 / 窗口），悬停时显示关闭按钮。
final class TabRowView: NSView {
    let key: BrowserTabKey
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private let marker = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let closeButton = IconButton(symbol: "xmark", tooltip: String(localized: "关闭标签页"))
    private var isActive = false

    var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }
    var isSelected = false { didSet { if isSelected != oldValue { refresh() } } }

    init(key: BrowserTabKey) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1.5
        iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.alignment = .right
        detailLabel.maximumNumberOfLines = 1
        closeButton.onPress = { [weak self] in
            self?.markClosing()
            self?.onClose?()
        }
        [marker, iconView, titleLabel, detailLabel, closeButton].forEach(addSubview)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func update(tab: BrowserTab, detail: String, isActive: Bool, style: TitleStyle) {
        self.isActive = isActive
        // 字号跟随标题样式；字重固定：普通标签常规，当前标签加粗，便于一眼区分。
        let font = NSFont.systemFont(ofSize: CGFloat(style.fontSize), weight: isActive ? .semibold : .regular)
        let title = tab.title.isEmpty ? tab.url : tab.title
        titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: OverlayColors.text(alpha: isActive ? 1 : 0.88)])
        detailLabel.attributedStringValue = NSAttributedString(string: detail, attributes: [.font: TitleRenderer.secondaryFont(for: style), .foregroundColor: OverlayColors.text(alpha: 0.5)])
        toolTip = tab.title + "\n" + tab.url
        alphaValue = 1
        refresh()
        needsLayout = true
    }

    /// 关闭请求已发出：变淡，等刷新结果移除。
    func markClosing() {
        alphaValue = 0.4
    }

    private func refresh() {
        layer?.backgroundColor = resolvedCGColor(isSelected ? OverlayColors.rowSelected : isHovered ? OverlayColors.rowHovered : .clear)
        marker.isHidden = !isActive
        marker.layer?.backgroundColor = resolvedCGColor(.controlAccentColor)
        iconView.contentTintColor = isActive ? .controlAccentColor : OverlayColors.text(alpha: 0.45)
        closeButton.isHidden = !isHovered
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        marker.frame = NSRect(x: 2, y: 6, width: 3, height: max(0, h - 12))
        iconView.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        let close: CGFloat = 22
        closeButton.frame = NSRect(x: bounds.width - close - 6, y: (h - close) / 2, width: close, height: close)
        let right = bounds.width - close - 12
        let detailWidth = min(ceil(detailLabel.attributedStringValue.size().width) + 4, bounds.width * 0.35)
        let titleX: CGFloat = 36
        let titleH = titleLabel.intrinsicContentSize.height
        let detailH = detailLabel.intrinsicContentSize.height
        detailLabel.frame = NSRect(x: right - detailWidth, y: (h - detailH) / 2, width: detailWidth, height: detailH)
        titleLabel.frame = NSRect(x: titleX, y: (h - titleH) / 2, width: max(0, right - detailWidth - 10 - titleX), height: titleH)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// 带文字的胶囊按钮（标签页视图中的"授权" / "打开系统设置"）。
final class PillButton: NSView {
    var onPress: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var isPressed = false { didSet { updateColors() } }

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.attributedStringValue = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    var fittingWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 36 }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    private func updateColors() {
        layer?.backgroundColor = resolvedCGColor(NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.7 : 1))
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}
