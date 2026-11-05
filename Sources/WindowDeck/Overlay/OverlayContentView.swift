import AppKit
import Carbon.HIToolbox
import WindowDeckCore

enum OverlayMode: Sendable, Equatable {
    /// 三指上滑：应用牌堆。
    case deck
    /// 三指下滑：当前应用窗口。
    case expose
}

@MainActor
protocol OverlayContentDelegate: AnyObject {
    func overlayFocus(_ window: WindowInfo, from content: OverlayContentView)
    func overlayPerform(_ action: CardAction, window: WindowInfo, card: CardView, from content: OverlayContentView)
    func overlayHideApp(_ pid: pid_t)
    func overlayQuitApp(_ pid: pid_t)
    func overlayActivateApp(_ pid: pid_t)
    func overlayDismiss()
    func overlaySwitchExposeApp(forward: Bool)
}

/// 一块屏幕上覆盖层需要展示的内容。
struct OverlayContext {
    var mode: OverlayMode
    var snapshot: CatalogSnapshot
    var settings: AppSettings
    /// 分配到本屏的窗口。
    var windowIDs: Set<CGWindowID>
    /// Exposé 视图的目标应用。
    var exposePID: pid_t?
    /// Deck 中显示没有窗口的应用（只在一块屏幕上显示）。
    var includeAppsWithoutWindows: Bool
}

/// 没有窗口的应用：一个图标牌，点击激活应用。
final class AppTileView: NSView {
    let pid: pid_t
    var onClick: (() -> Void)?
    private let icon = NSImageView()

    init(pid: pid_t) {
        self.pid = pid
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        applyColors()
        icon.image = NSRunningApplication(processIdentifier: pid)?.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
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
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(OverlayColors.tileBackground)
        layer?.borderColor = resolvedCGColor(OverlayColors.tileBorder)
    }

    override func layout() {
        super.layout()
        let side = min(min(bounds.width, bounds.height) * 0.5, 96)
        icon.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// 可滚动画布：接收鼠标移动与空白处点击。
final class OverlayCanvasView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        onBackgroundClick?()
    }
}

/// 一块屏幕上的覆盖层内容：背景、牌堆 / 窗口卡片、键盘与鼠标交互。
final class OverlayContentView: NSView {
    enum Animation {
        /// 卡片从窗口真实位置飞入。
        case flyIn
        /// 内容变化（关闭 / 收起窗口、切换应用）。
        case transition
        case none
    }

    private struct CardSpec {
        var window: WindowInfo
        var app: AppInfo
        var title: FormattedTitle
        var style: CardStyle
        var frame: CGRect
        var navRect: CGRect
        var depth: Int
        var isOverflow: Bool
    }

    private struct HeaderSpec {
        var app: AppInfo
        var frame: CGRect
        var windowCount: Int
        var alignment: NSTextAlignment
    }

    private struct LabelSpec {
        var text: String
        var frame: CGRect
        var size: CGFloat
        var alpha: CGFloat
        var background: Bool
    }

    private struct Model {
        var cards: [CardSpec] = []
        var headers: [HeaderSpec] = []
        var panels: [(pid: pid_t, frame: CGRect)] = []
        var tiles: [(pid: pid_t, frame: CGRect)] = []
        var labels: [LabelSpec] = []
        var overflow: [(pid: pid_t, text: String, frame: CGRect)] = []
        var contentHeight: CGFloat = 0
        var decks: [pid_t: DeckFrame] = [:]
        var deckWindows: [pid_t: [CGWindowID]] = [:]
    }

    weak var delegate: OverlayContentDelegate?
    let screen: NSScreen
    private(set) var context: OverlayContext
    private let thumbnails: ThumbnailService

    private let effectView = NSVisualEffectView()
    private let dimView = NSView()
    private let scrollView = NSScrollView()
    private let canvas = OverlayCanvasView()

    private var model = Model()
    private var cards: [CGWindowID: CardView] = [:]
    private var headers: [pid_t: AppHeaderView] = [:]
    private var panelViews: [pid_t: PanelBackgroundView] = [:]
    private var tileViews: [pid_t: AppTileView] = [:]
    private var labelViews: [OverlayLabel] = []
    private var overflowViews: [BadgeView] = []
    private var fadingViews: [NSView] = []

    private(set) var selectedID: CGWindowID?
    private var hoveredCardID: CGWindowID?
    private var hoveredHeaderPID: pid_t?
    private var expandedPID: pid_t?
    private var expansionBackdrop: PanelBackgroundView?
    private var expansionFrames: [CGWindowID: CGRect] = [:]
    private var pendingExpansion: DispatchWorkItem?
    private var pendingPopup: DispatchWorkItem?
    private var fullTitlePopup: OverlayLabel?
    private var toastView: OverlayLabel?

    init(screen: NSScreen, context: OverlayContext, thumbnails: ThumbnailService) {
        self.screen = screen
        self.context = context
        self.thumbnails = thumbnails
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true

        effectView.material = .fullScreenUI
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = resolvedCGColor(OverlayColors.dim)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = canvas
        canvas.wantsLayer = true

        [effectView, dimView, scrollView].forEach(addSubview)

        canvas.onMouseMoved = { [weak self] point in self?.updateHover(at: point) }
        canvas.onMouseExited = { [weak self] in self?.updateHover(at: nil) }
        canvas.onBackgroundClick = { [weak self] in self?.delegate?.overlayDismiss() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dimView.layer?.backgroundColor = resolvedCGColor(OverlayColors.dim)
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        dimView.frame = bounds
        scrollView.frame = bounds
    }

    private var settings: AppSettings { context.settings }

    private var reduceMotion: Bool {
        switch settings.appearance.reduceMotion {
        case .on: true
        case .off: false
        case .system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: 构建

    /// 首次展示：背景淡入，卡片飞入。
    func present() {
        dimView.alphaValue = 0
        effectView.alphaValue = 0
        apply(context: context, animation: reduceMotion ? .none : .flyIn)
        let duration = reduceMotion ? 0.12 : 0.18
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            effectView.animator().alphaValue = 1
            dimView.animator().alphaValue = CGFloat(settings.appearance.dimOpacity)
        }
        if reduceMotion {
            canvas.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                canvas.animator().alphaValue = 1
            }
        }
    }

    /// 收起：聚焦的卡片飞回窗口位置，其余淡出。
    func dismiss(focusing windowID: CGWindowID?, completion: @escaping @MainActor () -> Void) {
        pendingExpansion?.cancel()
        pendingPopup?.cancel()
        fullTitlePopup?.removeFromSuperview()
        let reduce = reduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.12 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            effectView.animator().alphaValue = 0
            dimView.animator().alphaValue = 0
            for (id, card) in cards {
                if !reduce, id == windowID, let start = startFrame(for: card.windowInfo) {
                    card.animator().frame = start
                    card.layoutSubtreeIfNeeded()
                } else {
                    card.animator().alphaValue = 0
                }
            }
            for view in canvas.subviews where !(view is CardView) {
                view.animator().alphaValue = 0
            }
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }

    /// 内容变化（快照更新、切换 Exposé 应用）。
    func update(context: OverlayContext, animation: Animation = .transition) {
        apply(context: context, animation: reduceMotion && animation != .none ? .none : animation)
    }

    func updateThumbnail(_ id: CGWindowID, image: CGImage) {
        cards[id]?.setThumbnail(image, animated: true)
    }

    var visibleWindows: [WindowInfo] {
        model.cards.filter { !$0.isOverflow }.map(\.window)
    }

    private func apply(context newContext: OverlayContext, animation: Animation) {
        context = newContext
        model = buildModel()
        let viewport = bounds.size
        canvas.frame = NSRect(x: 0, y: 0, width: viewport.width, height: max(viewport.height, model.contentHeight))
        scrollView.hasVerticalScroller = model.contentHeight > viewport.height

        applyPanels(animation: animation)
        applyCards(animation: animation)
        applyHeaders(animation: animation)
        applyLabels()
        reorderSubviews()

        if let pid = expandedPID {
            if (model.deckWindows[pid]?.count ?? 0) > 1 {
                expand(pid, animated: animation != .none)
            } else {
                collapse(animated: false)
            }
        }
        if let selected = selectedID, cards[selected] == nil {
            selectedID = nil
        }
    }

    private var contentInsets: NSEdgeInsets {
        let f = screen.frame
        let v = screen.visibleFrame
        return NSEdgeInsets(
            top: max(f.maxY - v.maxY, 0) + 36,
            left: max(v.minX - f.minX, 0) + 48,
            bottom: max(v.minY - f.minY, 0) + 36,
            right: max(f.maxX - v.maxX, 0) + 48
        )
    }

    private func buildModel() -> Model {
        let insets = contentInsets
        let bounds = CGRect(
            x: insets.left,
            y: insets.top,
            width: max(self.bounds.width - insets.left - insets.right, 100),
            height: max(self.bounds.height - insets.top - insets.bottom, 100)
        )
        var model: Model
        switch (context.mode, settings.showThumbnails) {
        case (.deck, true): model = buildDeck(bounds: bounds)
        case (.deck, false): model = buildTitleList(bounds: bounds, apps: deckApps())
        case (.expose, true): model = buildExpose(bounds: bounds)
        case (.expose, false):
            var top = bounds
            var labels: [LabelSpec] = []
            if let app = exposeApp {
                labels.append(exposeTitleLabel(app: app, bounds: bounds))
                top.origin.y += 48
                top.size.height -= 48
            }
            model = buildTitleList(bounds: top, apps: exposeApp.map { [$0] } ?? [])
            model.labels += labels
        }
        if model.cards.isEmpty, model.tiles.isEmpty {
            let text: String
            switch context.mode {
            case .deck: text = String(localized: "没有可显示的窗口")
            case .expose: text = exposeApp.map { String(localized: "「\($0.name)」没有可显示的窗口") } ?? String(localized: "没有当前应用")
            }
            model.labels.append(LabelSpec(text: text, frame: CGRect(x: bounds.minX, y: bounds.midY - 20, width: bounds.width, height: 40), size: 20, alpha: 0.7, background: false))
        }
        model.contentHeight = max(model.contentHeight + insets.top + insets.bottom, self.bounds.height)
        return model
    }

    private func windows(of app: AppInfo) -> [WindowInfo] {
        app.windowIDs.compactMap { id in
            context.windowIDs.contains(id) ? context.snapshot.windows[id] : nil
        }
    }

    private func deckApps() -> [AppInfo] {
        context.snapshot.apps.filter { app in
            !windows(of: app).isEmpty || (context.includeAppsWithoutWindows && settings.deck.showAppsWithoutWindows)
        }
    }

    private var exposeApp: AppInfo? {
        context.exposePID.flatMap { context.snapshot.app(pid: $0) }
    }

    private func formattedTitles(_ windows: [WindowInfo], app: AppInfo) -> [CGWindowID: FormattedTitle] {
        let formatted = TitleFormatter.format(titles: windows.map(\.title), appName: app.name, cleanup: settings.titleCleanup)
        return Dictionary(uniqueKeysWithValues: zip(windows.map(\.id), formatted))
    }

    private func buildDeck(bounds: CGRect) -> Model {
        var model = Model()
        let apps = deckApps()
        let band = TitleRenderer.bandHeight(for: settings.titleStyle)
        let items = apps.map { DeckItem(appID: $0.pid, windowIDs: windows(of: $0).map(\.id)) }
        let result = DeckLayout.compute(DeckLayoutInput(
            decks: items,
            bounds: bounds,
            titleBandHeight: band,
            contentPeek: CGFloat(settings.deck.contentPeek),
            maxStackDepth: settings.deck.maxStackDepth,
            headerHeight: 34
        ))
        model.contentHeight = result.needsScrolling ? result.contentSize.height : bounds.height
        for (app, deck) in zip(apps, result.decks) {
            let list = windows(of: app)
            model.decks[app.pid] = deck
            model.deckWindows[app.pid] = list.map(\.id)
            model.headers.append(HeaderSpec(app: app, frame: deck.headerFrame, windowCount: list.count, alignment: .center))
            guard let top = deck.cards.last else {
                let card = result.cardSize
                model.tiles.append((app.pid, CGRect(x: deck.headerFrame.midX - card.width / 2, y: deck.headerFrame.minY - card.height, width: card.width, height: card.height)))
                continue
            }
            let titles = formattedTitles(list, app: app)
            // z-order：深层在下，最前卡片在上；超出层数的窗口隐藏在最顶层卡片后面，展开时出现。
            for (index, window) in list.enumerated().reversed() {
                let spec: CardSpec
                if index < deck.cards.count {
                    let f = deck.cards[index]
                    spec = CardSpec(window: window, app: app, title: titles[window.id] ?? FormattedTitle(core: window.title), style: .deck, frame: f.frame, navRect: f.visibleFrame, depth: index, isOverflow: false)
                } else {
                    spec = CardSpec(window: window, app: app, title: titles[window.id] ?? FormattedTitle(core: window.title), style: .deck, frame: top.frame, navRect: .zero, depth: index, isOverflow: true)
                }
                model.cards.append(spec)
            }
            if deck.overflowCount > 0 {
                let text = "+\(deck.overflowCount)"
                let width = ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).size().width) + 26
                model.overflow.append((app.pid, text, CGRect(x: top.frame.maxX - width, y: top.frame.minY - 28, width: width, height: 24)))
            }
        }
        return model
    }

    private func exposeTitleLabel(app: AppInfo, bounds: CGRect) -> LabelSpec {
        let others = context.snapshot.apps.filter { !$0.windowIDs.isEmpty && $0.pid != app.pid }.count
        let hint = others > 0 ? "    " + String(localized: "⇥ 切换应用") : ""
        return LabelSpec(text: app.name + hint, frame: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 30), size: 17, alpha: 0.85, background: false)
    }

    private func buildExpose(bounds: CGRect) -> Model {
        var model = Model()
        model.contentHeight = bounds.height
        guard let app = exposeApp else { return model }
        let list = windows(of: app)
        let titles = formattedTitles(list, app: app)
        model.labels.append(exposeTitleLabel(app: app, bounds: bounds))

        let stripWindows = list.filter {
            ($0.isMinimized && settings.expose.showMinimizedStrip) || (!$0.isOnCurrentSpace && settings.expose.groupOtherSpaces)
        }
        let stripIDs = Set(stripWindows.map(\.id))
        let mainWindows = list.filter { !stripIDs.contains($0.id) }
        let band = TitleRenderer.bandHeight(for: settings.titleStyle)

        var main = bounds
        main.origin.y += 44
        main.size.height -= 44
        if !stripWindows.isEmpty {
            let stripHeight = min(max(bounds.height * 0.22, band + 70), 220)
            main.size.height -= stripHeight + 30
            let labelY = main.maxY + 12
            var parts: [String] = []
            if stripWindows.contains(where: \.isMinimized) { parts.append(String(localized: "已收起")) }
            if stripWindows.contains(where: { !$0.isOnCurrentSpace }) { parts.append(String(localized: "其他桌面")) }
            model.labels.append(LabelSpec(text: parts.joined(separator: " · "), frame: CGRect(x: bounds.minX, y: labelY, width: bounds.width, height: 20), size: 13, alpha: 0.6, background: false))
            let strip = CGRect(x: bounds.minX, y: labelY + 26, width: bounds.width, height: bounds.maxY - labelY - 26)
            let result = ExposeLayout.compute(ExposeLayoutInput(
                items: stripWindows.map { LayoutItem(id: $0.id, size: $0.frame.size) },
                bounds: strip,
                titleBandHeight: band,
                spacing: 16,
                maxScale: 0.35,
                maxRows: 1
            ))
            for window in stripWindows {
                guard let frame = result.frames[window.id] else { continue }
                model.cards.append(CardSpec(window: window, app: app, title: titles[window.id] ?? FormattedTitle(core: window.title), style: .expose, frame: frame, navRect: frame, depth: 0, isOverflow: false))
            }
        }
        let result = ExposeLayout.compute(ExposeLayoutInput(
            items: mainWindows.map { LayoutItem(id: $0.id, size: $0.frame.size) },
            bounds: main,
            titleBandHeight: band,
            spacing: 28
        ))
        for window in mainWindows {
            guard let frame = result.frames[window.id] else { continue }
            model.cards.append(CardSpec(window: window, app: app, title: titles[window.id] ?? FormattedTitle(core: window.title), style: .expose, frame: frame, navRect: frame, depth: 0, isOverflow: false))
        }
        return model
    }

    private func buildTitleList(bounds: CGRect, apps: [AppInfo]) -> Model {
        var model = Model()
        let groups = apps.compactMap { app -> TitleListGroup? in
            let ids = windows(of: app).map(\.id)
            return ids.isEmpty ? nil : TitleListGroup(appID: app.pid, windowIDs: ids)
        }
        let rowHeight = max(TitleRenderer.bandHeight(for: settings.titleStyle) + 6, 36)
        let result = TitleListLayout.compute(TitleListLayoutInput(groups: groups, bounds: bounds, rowHeight: rowHeight, headerHeight: 40))
        model.contentHeight = result.needsScrolling ? result.contentSize.height : bounds.height
        for group in result.groups {
            guard let app = context.snapshot.app(pid: group.appID) else { continue }
            let list = windows(of: app)
            let titles = formattedTitles(list, app: app)
            model.panels.append((app.pid, group.frame))
            model.headers.append(HeaderSpec(app: app, frame: group.headerFrame.insetBy(dx: 14, dy: 0), windowCount: list.count, alignment: .left))
            for window in list {
                guard let row = group.rows[window.id] else { continue }
                let frame = row.insetBy(dx: 6, dy: 2)
                model.cards.append(CardSpec(window: window, app: app, title: titles[window.id] ?? FormattedTitle(core: window.title), style: .row, frame: frame, navRect: frame, depth: 0, isOverflow: false))
            }
        }
        return model
    }

    // MARK: 视图同步

    /// 窗口在本屏上的真实位置（覆盖层坐标）；不在本屏、已收起或在其他桌面时返回 nil。
    private func startFrame(for window: WindowInfo) -> CGRect? {
        guard window.isOnCurrentSpace, !window.isMinimized,
              context.snapshot.app(pid: window.pid)?.isHidden != true else { return nil }
        let rect = CoordinateConverter.overlayRect(fromAX: window.frame, screen: screen)
        guard rect.intersects(bounds) else { return nil }
        return rect
    }

    private func animate(_ animation: Animation, _ changes: @escaping () -> Void, completion: (@MainActor () -> Void)? = nil) {
        guard animation != .none else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animation == .flyIn ? 0.26 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    private func applyCards(animation: Animation) {
        var seen = Set<CGWindowID>()
        var moves: [(CardView, CGRect, CGFloat)] = []
        for spec in model.cards {
            seen.insert(spec.window.id)
            let targetAlpha: CGFloat = spec.isOverflow ? 0 : 1
            if let card = cards[spec.window.id] {
                card.update(window: spec.window, app: spec.app, title: spec.title, style: spec.style, settings: settings)
                card.deckDepth = spec.depth
                card.isOverflow = spec.isOverflow
                moves.append((card, spec.frame, targetAlpha))
                continue
            }
            let card = CardView(window: spec.window, app: spec.app, title: spec.title, style: spec.style, settings: settings)
            card.deckDepth = spec.depth
            card.isOverflow = spec.isOverflow
            if spec.style != .row {
                card.setThumbnail(thumbnails.cached(spec.window.id), animated: false)
            }
            card.onAction = { [weak self, weak card] action in
                guard let self, let card else { return }
                self.handle(action, card: card)
            }
            cards[spec.window.id] = card
            canvas.addSubview(card)
            switch animation {
            case .flyIn:
                if spec.style != .row, !spec.isOverflow, let start = startFrame(for: spec.window) {
                    card.frame = start
                    card.alphaValue = 1
                } else {
                    card.frame = spec.frame.insetBy(dx: spec.frame.width * 0.04, dy: spec.frame.height * 0.04)
                    card.alphaValue = 0
                }
            case .transition:
                card.frame = spec.frame
                card.alphaValue = 0
            case .none:
                card.frame = spec.frame
                card.alphaValue = targetAlpha
            }
            card.layoutSubtreeIfNeeded()
            moves.append((card, spec.frame, targetAlpha))
        }

        let removed = cards.filter { !seen.contains($0.key) }
        for (id, card) in removed {
            cards[id] = nil
            fadingViews.append(card)
        }
        if hoveredCardID.map({ !seen.contains($0) }) ?? false { hoveredCardID = nil }

        animate(animation, {
            for (card, frame, alpha) in moves {
                card.animator().frame = frame
                card.animator().alphaValue = alpha
                card.layoutSubtreeIfNeeded()
            }
            for (_, card) in removed {
                card.animator().alphaValue = 0
            }
        }, completion: { [weak self] in
            for (_, card) in removed { card.removeFromSuperview() }
            self?.fadingViews.removeAll { view in removed.contains { $0.value === view } }
        })
    }

    private func applyHeaders(animation: Animation) {
        var seen = Set<pid_t>()
        for spec in model.headers {
            seen.insert(spec.app.pid)
            let header: AppHeaderView
            if let existing = headers[spec.app.pid] {
                header = existing
                header.update(app: spec.app, windowCount: spec.windowCount)
                animate(animation == .flyIn ? .none : animation) { header.animator().frame = spec.frame }
            } else {
                header = AppHeaderView(app: spec.app, windowCount: spec.windowCount, alignment: spec.alignment)
                let pid = spec.app.pid
                header.onHide = { [weak self] in self?.delegate?.overlayHideApp(pid) }
                header.onQuit = { [weak self] in self?.delegate?.overlayQuitApp(pid) }
                header.onClick = { [weak self] in self?.focusFrontWindow(of: pid) }
                header.frame = spec.frame
                headers[pid] = header
                canvas.addSubview(header)
                if animation != .none {
                    header.alphaValue = 0
                    animate(.transition) { header.animator().alphaValue = 1 }
                }
            }
        }
        for (pid, header) in headers where !seen.contains(pid) {
            header.removeFromSuperview()
            headers[pid] = nil
        }

        var seenTiles = Set<pid_t>()
        for (pid, frame) in model.tiles {
            seenTiles.insert(pid)
            let tile = tileViews[pid] ?? {
                let t = AppTileView(pid: pid)
                t.onClick = { [weak self] in self?.delegate?.overlayActivateApp(pid) }
                tileViews[pid] = t
                canvas.addSubview(t)
                return t
            }()
            tile.frame = frame
        }
        for (pid, tile) in tileViews where !seenTiles.contains(pid) {
            tile.removeFromSuperview()
            tileViews[pid] = nil
        }
    }

    private func applyPanels(animation: Animation) {
        var seen = Set<pid_t>()
        for (pid, frame) in model.panels {
            seen.insert(pid)
            if let panel = panelViews[pid] {
                animate(animation == .flyIn ? .none : animation) { panel.animator().frame = frame }
            } else {
                let panel = PanelBackgroundView()
                panel.frame = frame
                panelViews[pid] = panel
                canvas.addSubview(panel)
            }
        }
        for (pid, panel) in panelViews where !seen.contains(pid) {
            panel.removeFromSuperview()
            panelViews[pid] = nil
        }
    }

    private func applyLabels() {
        labelViews.forEach { $0.removeFromSuperview() }
        overflowViews.forEach { $0.removeFromSuperview() }
        labelViews = model.labels.map { spec in
            let label = OverlayLabel(text: spec.text, size: spec.size, alpha: spec.alpha, background: spec.background)
            label.frame = spec.frame
            canvas.addSubview(label)
            return label
        }
        overflowViews = model.overflow.map { item in
            let badge = BadgeView(text: item.text)
            let width = badge.fittingWidth
            badge.frame = CGRect(x: item.frame.maxX - width, y: item.frame.minY, width: width, height: 22)
            canvas.addSubview(badge)
            return badge
        }
    }

    /// 子视图前后顺序：面板 → 图标牌 → 卡片（按模型顺序）→ 应用标题 → 文本 → 展开层 → 浮层。
    private func reorderSubviews() {
        var ordered: [NSView] = []
        ordered += model.panels.compactMap { panelViews[$0.pid] }
        ordered += model.tiles.compactMap { tileViews[$0.pid] }
        ordered += model.cards.compactMap { cards[$0.window.id] }
        ordered += model.headers.compactMap { headers[$0.app.pid] }
        ordered += labelViews
        ordered += overflowViews
        ordered += fadingViews
        if let pid = expandedPID, let backdrop = expansionBackdrop {
            let ids = Set(model.deckWindows[pid] ?? [])
            ordered.removeAll { ($0 as? CardView).map { ids.contains($0.windowID) } ?? false }
            ordered.append(backdrop)
            ordered += (model.deckWindows[pid] ?? []).reversed().compactMap { cards[$0] }
        }
        if let popup = fullTitlePopup { ordered.append(popup) }
        if let toast = toastView { ordered.append(toast) }
        canvas.subviews = ordered
    }

    // MARK: 悬停与展开

    private func updateHover(at point: NSPoint?) {
        var cardID: CGWindowID?
        var headerPID: pid_t?
        if let point {
            var view = canvas.hitTest(point)
            while let v = view, v !== canvas {
                if let card = v as? CardView, card.alphaValue > 0.01 {
                    cardID = card.windowID
                    break
                }
                if let header = v as? AppHeaderView {
                    headerPID = header.pid
                    break
                }
                view = v.superview
            }
        }
        if headerPID != hoveredHeaderPID {
            if let old = hoveredHeaderPID { headers[old]?.isHovered = false }
            hoveredHeaderPID = headerPID
            if let headerPID { headers[headerPID]?.isHovered = true }
        }
        if cardID != hoveredCardID {
            if let old = hoveredCardID { cards[old]?.isHovered = false }
            hoveredCardID = cardID
            if let cardID {
                cards[cardID]?.isHovered = true
                select(cardID)
            }
            scheduleFullTitlePopup()
        }

        // 展开：悬停在某个牌堆上 300ms 后展开；离开展开区域后收拢。
        guard context.mode == .deck, settings.showThumbnails, settings.deck.expandOnHover else { return }
        if let expandedPID, let backdrop = expansionBackdrop {
            if let point, backdrop.frame.insetBy(dx: -12, dy: -12).contains(point) { return }
            if let cardID, cards[cardID]?.app.pid == expandedPID { return }
            collapse(animated: true)
        }
        let hoveredPID = cardID.flatMap { cards[$0]?.app.pid }
        pendingExpansion?.cancel()
        pendingExpansion = nil
        guard let pid = hoveredPID, pid != expandedPID, (model.deckWindows[pid]?.count ?? 0) > 1 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.expand(pid, animated: true) }
        }
        pendingExpansion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func expand(_ pid: pid_t, animated: Bool) {
        guard let deck = model.decks[pid], let ids = model.deckWindows[pid], ids.count > 1 else { return }
        let viewport = CGRect(origin: scrollView.contentView.bounds.origin, size: bounds.size)
        let insets = contentInsets
        let limit = CGRect(x: insets.left, y: viewport.minY + insets.top, width: bounds.width - insets.left - insets.right, height: bounds.height - insets.top - insets.bottom)
        let region = DeckLayout.expansionRegion(cell: deck.cellFrame, bounds: limit, factor: ids.count > 4 ? 2.0 : 1.6)
        let windows = ids.compactMap { context.snapshot.windows[$0] }
        let band = TitleRenderer.bandHeight(for: settings.titleStyle)
        let result = ExposeLayout.compute(ExposeLayoutInput(
            items: windows.map { LayoutItem(id: $0.id, size: $0.frame.size) },
            bounds: region.insetBy(dx: 16, dy: 16),
            titleBandHeight: band,
            spacing: 16
        ))
        expansionFrames = result.frames
        expandedPID = pid
        let backdrop = expansionBackdrop ?? PanelBackgroundView(cornerRadius: 18, alpha: 0.72)
        if expansionBackdrop == nil {
            backdrop.frame = deck.stackFrame
            backdrop.alphaValue = 0
        }
        expansionBackdrop = backdrop
        reorderSubviews()
        animate(animated ? .transition : .none) {
            backdrop.animator().frame = region
            backdrop.animator().alphaValue = 1
            for id in ids {
                guard let card = self.cards[id], let frame = result.frames[id] else { continue }
                card.animator().frame = frame
                card.animator().alphaValue = 1
                card.layoutSubtreeIfNeeded()
            }
        }
    }

    private func collapse(animated: Bool) {
        guard let pid = expandedPID else { return }
        expandedPID = nil
        expansionFrames = [:]
        let backdrop = expansionBackdrop
        expansionBackdrop = nil
        let specs = model.cards.filter { $0.app.pid == pid }
        let deckFrame = model.decks[pid]?.stackFrame
        animate(animated ? .transition : .none, {
            for spec in specs {
                guard let card = self.cards[spec.window.id] else { continue }
                card.animator().frame = spec.frame
                card.animator().alphaValue = spec.isOverflow ? 0 : 1
                card.layoutSubtreeIfNeeded()
            }
            if let deckFrame { backdrop?.animator().frame = deckFrame }
            backdrop?.animator().alphaValue = 0
        }, completion: { [weak self] in
            backdrop?.removeFromSuperview()
            self?.reorderSubviews()
        })
    }

    private func scheduleFullTitlePopup() {
        pendingPopup?.cancel()
        fullTitlePopup?.removeFromSuperview()
        fullTitlePopup = nil
        guard let id = hoveredCardID, let card = cards[id], card.isTitleTruncated else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showFullTitle(for: id) }
        }
        pendingPopup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func showFullTitle(for id: CGWindowID) {
        guard hoveredCardID == id, let card = cards[id] else { return }
        let popup = OverlayLabel(text: card.fullTitle, size: max(13, CGFloat(settings.titleStyle.fontSize) * 0.8), weight: .medium, alpha: 0.95, background: true)
        let maxWidth = min(560, canvas.bounds.width - 40)
        let size = popup.fittingSize(maxWidth: maxWidth)
        let band = card.convert(card.titleBandFrame, to: canvas)
        var origin = CGPoint(x: band.midX - size.width / 2, y: band.maxY + 6)
        if origin.y + size.height > canvas.bounds.maxY - 8 { origin.y = band.minY - size.height - 6 }
        origin.x = min(max(origin.x, 12), canvas.bounds.width - size.width - 12)
        popup.frame = CGRect(origin: origin, size: size)
        fullTitlePopup = popup
        canvas.addSubview(popup)
    }

    func showToast(_ text: String) {
        toastView?.removeFromSuperview()
        let toast = OverlayLabel(text: text, size: 14, weight: .medium, alpha: 0.95, background: true)
        let size = toast.fittingSize(maxWidth: 420)
        let visible = scrollView.contentView.bounds
        toast.frame = CGRect(x: (bounds.width - size.width) / 2, y: visible.maxY - contentInsets.bottom - size.height, width: size.width, height: size.height)
        toastView = toast
        canvas.addSubview(toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak toast] in
            MainActor.assumeIsolated {
                guard let toast else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    toast.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        toast.removeFromSuperview()
                        if self?.toastView === toast { self?.toastView = nil }
                    }
                })
            }
        }
    }

    // MARK: 选择与键盘

    private func select(_ id: CGWindowID?) {
        guard id != selectedID else { return }
        if let old = selectedID { cards[old]?.isSelected = false }
        selectedID = id
        if let id, let card = cards[id] {
            card.isSelected = true
            scrollView.contentView.scrollToVisible(card.frame.insetBy(dx: 0, dy: -24))
        }
    }

    private var navigationTargets: [(id: CGWindowID, rect: CGRect)] {
        model.cards.compactMap { spec in
            if let frame = expansionFrames[spec.window.id] { return (spec.window.id, frame) }
            if let pid = expandedPID, spec.app.pid == pid { return nil }
            guard !spec.isOverflow else { return nil }
            return (spec.window.id, spec.navRect)
        }
        // 按视觉顺序（自上而下、自左向右）排列，便于"第一个"的选择。
        .sorted { a, b in
            abs(a.rect.minY - b.rect.minY) < 4 ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape:
            delegate?.overlayDismiss()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let id = selectedID, let window = cards[id]?.windowInfo {
                delegate?.overlayFocus(window, from: self)
            } else if let first = firstSelectableID, let window = cards[first]?.windowInfo {
                delegate?.overlayFocus(window, from: self)
            }
        case kVK_LeftArrow: navigate(.left)
        case kVK_RightArrow: navigate(.right)
        case kVK_UpArrow: navigate(.up)
        case kVK_DownArrow: navigate(.down)
        case kVK_Tab:
            if context.mode == .expose {
                delegate?.overlaySwitchExposeApp(forward: !flags.contains(.shift))
            } else {
                navigate(flags.contains(.shift) ? .left : .right)
            }
        case kVK_ANSI_W where flags.contains(.command):
            if let id = selectedID, let card = cards[id] { handle(.close, card: card) }
        case kVK_ANSI_M where flags.contains(.command):
            if let id = selectedID, let card = cards[id] { handle(.toggleMinimize, card: card) }
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        delegate?.overlayDismiss()
    }

    private var firstSelectableID: CGWindowID? {
        if context.mode == .deck {
            // Deck：默认是第一个牌堆的最前卡片（最近使用的窗口）。
            return model.cards.first { $0.depth == 0 && !$0.isOverflow }.map(\.window.id) ?? navigationTargets.first?.id
        }
        return model.cards.last?.window.id ?? navigationTargets.first?.id
    }

    private func navigate(_ direction: NavigationDirection) {
        guard selectedID != nil else {
            select(firstSelectableID)
            return
        }
        select(SpatialNavigation.next(from: selectedID, direction: direction, targets: navigationTargets))
    }

    // MARK: 操作

    private func handle(_ action: CardAction, card: CardView) {
        switch action {
        case .focus:
            delegate?.overlayFocus(card.windowInfo, from: self)
        case let .hint(text):
            showToast(text)
        case .close, .toggleMinimize, .green:
            delegate?.overlayPerform(action, window: card.windowInfo, card: card, from: self)
        }
    }

    private func focusFrontWindow(of pid: pid_t) {
        if let id = model.deckWindows[pid]?.first ?? model.cards.first(where: { $0.app.pid == pid })?.window.id,
           let window = cards[id]?.windowInfo {
            delegate?.overlayFocus(window, from: self)
        } else {
            delegate?.overlayActivateApp(pid)
        }
    }

    func card(for id: CGWindowID) -> CardView? { cards[id] }
}
