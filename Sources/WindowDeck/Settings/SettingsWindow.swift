import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WindowDeckCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, deck, expose, trafficLights, filter, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .appearance: String(localized: "外观")
        case .deck: String(localized: "牌堆")
        case .expose: String(localized: "当前应用")
        case .trafficLights: String(localized: "红绿灯")
        case .filter: String(localized: "过滤")
        case .diagnostics: String(localized: "权限与诊断")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .deck: "rectangle.stack"
        case .expose: "macwindow.on.rectangle"
        case .trafficLights: "circle.circle"
        case .filter: "line.3.horizontal.decrease.circle"
        case .diagnostics: "stethoscope"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let navigation = SettingsNavigation()

    init(app: AppDelegate) {
        let root = SettingsView(app: app, store: app.settingsStore, navigation: navigation)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "WindowDeck 设置")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab?) {
        if let tab { navigation.tab = tab }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let app: AppDelegate
    @Bindable var store: SettingsStore
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $navigation.tab) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            Group {
                switch navigation.tab {
                case .general: GeneralSettings(app: app, store: store)
                case .appearance: AppearanceSettingsView(store: store)
                case .deck: DeckSettingsView(store: store)
                case .expose: ExposeSettingsView(store: store)
                case .trafficLights: TrafficLightSettingsView(store: store)
                case .filter: FilterSettingsView(store: store)
                case .diagnostics: DiagnosticsView(app: app, store: store)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigation.tab.title)
        }
    }
}

// MARK: 通用

private struct GeneralSettings: View {
    let app: AppDelegate
    @Bindable var store: SettingsStore
    // CommandLineTools 工具链缺少 SwiftUI 宏插件，直接使用 State 属性包装器类型（同 HotkeyRecorder）。
    private let languageState = State(initialValue: AppLanguage.current)

    private var language: AppLanguage {
        get { languageState.wrappedValue }
        nonmutating set { languageState.wrappedValue = newValue }
    }

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动", isOn: $store.settings.launchAtLogin)
                Picker("语言", selection: Binding(get: { language }, set: { language = $0; $0.apply() })) {
                    Text("跟随系统").tag(AppLanguage.system)
                    // 语言名称始终用该语言本身显示，不翻译。
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                if language != AppLanguage.atLaunch {
                    HStack {
                        Text("重新启动后生效。").foregroundStyle(.secondary)
                        Spacer()
                        Button("重新启动 WindowDeck") { PermissionService.relaunch() }
                    }
                }
            }
            Section("触控板手势") {
                if !app.capabilities.gesture {
                    Label("当前系统上无法读取触控板数据，请使用快捷键。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Toggle("启用手势（上滑显示牌堆，下滑显示当前应用窗口）", isOn: $store.settings.gesture.enabled)
                    .disabled(!app.capabilities.gesture)
                Picker("手指数", selection: $store.settings.gesture.fingers) {
                    Text("三指").tag(3)
                    Text("四指").tag(4)
                }
                .pickerStyle(.segmented)
                LabeledContent("灵敏度") {
                    Slider(value: $store.settings.gesture.sensitivity, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("低")
                    } maximumValueLabel: {
                        Text("高")
                    }
                }
                ConflictRow(status: GestureConflictStatus.detect(fingers: store.settings.gesture.fingers))
            }
            Section {
                LabeledContent("显示牌堆") {
                    HotkeyRecorder(combo: $store.settings.hotkeys.deck, conflict: app.hotkeys.failedSlots.contains(.deck)) { recording in
                        app.hotkeys.setSuspended(recording)
                    }
                }
                LabeledContent("显示当前应用窗口") {
                    HotkeyRecorder(combo: $store.settings.hotkeys.expose, conflict: app.hotkeys.failedSlots.contains(.expose)) { recording in
                        app.hotkeys.setSuspended(recording)
                    }
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("默认不设置快捷键。按同一快捷键可收起，按另一个快捷键可在两个视图间切换。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConflictRow: View {
    let status: GestureConflictStatus

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: status.hasConflict || status.dragConflict ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(status.hasConflict || status.dragConflict ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.summary)
                if status.hasConflict {
                    Text("关闭系统手势后，仍可用 ⌃↑ / ⌃↓ 或 F3 打开系统自带的调度中心。WindowDeck 不会修改系统设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status.hasConflict || status.dragConflict {
                Button("打开触控板设置") { PermissionService.openTrackpadSettings() }
            }
        }
    }
}

// MARK: 外观

private struct AppearanceSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("应用主题", selection: $store.settings.appearance.theme) {
                    Text("跟随系统").tag(AppTheme.system)
                    Text("浅色").tag(AppTheme.light)
                    Text("深色").tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
                Picker("覆盖层主题", selection: $store.settings.appearance.overlayTheme) {
                    Text("跟随应用").tag(OverlayTheme.followApp)
                    Text("浅色").tag(OverlayTheme.light)
                    Text("深色").tag(OverlayTheme.dark)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("应用主题作用于设置窗口与引导窗口；覆盖层主题作用于牌堆和当前应用界面。")
                    .foregroundStyle(.secondary)
            }
            Section("窗口内容") {
                Toggle("显示窗口缩略图", isOn: $store.settings.showThumbnails)
                Text("关闭后为\"仅标题\"模式：只显示应用和窗口标题，不需要屏幕录制权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("画质", selection: $store.settings.thumbnailQuality) {
                    Text("省内存").tag(ThumbnailQuality.low)
                    Text("均衡").tag(ThumbnailQuality.balanced)
                    Text("清晰").tag(ThumbnailQuality.high)
                }
                .disabled(!store.settings.showThumbnails)
            }
            Section("标题") {
                LabeledContent("字号 \(Int(store.settings.titleStyle.fontSize))") {
                    Slider(value: $store.settings.titleStyle.fontSize, in: TitleStyle.fontSizeRange, step: 1)
                }
                Picker("字重", selection: $store.settings.titleStyle.weight) {
                    Text("常规").tag(FontWeight.regular)
                    Text("中等").tag(FontWeight.medium)
                    Text("半粗").tag(FontWeight.semibold)
                    Text("粗体").tag(FontWeight.bold)
                }
                Stepper("最多 \(store.settings.titleStyle.maxLines) 行", value: $store.settings.titleStyle.maxLines, in: TitleStyle.maxLinesRange)
                Picker("过长时截断", selection: $store.settings.titleStyle.truncation) {
                    Text("开头").tag(Truncation.head)
                    Text("中间").tag(Truncation.middle)
                    Text("末尾").tag(Truncation.tail)
                }
                Picker("标题背景", selection: $store.settings.titleStyle.background) {
                    Text("无").tag(TitleBackground.none)
                    Text("胶囊").tag(TitleBackground.pill)
                    Text("整条").tag(TitleBackground.bar)
                }
                Toggle("标题前显示应用名", isOn: $store.settings.titleStyle.showAppNamePrefix)
                Toggle("去掉标题末尾的应用名", isOn: $store.settings.titleCleanup.stripAppSuffix)
                Toggle("弱化同一应用窗口标题的相同部分", isOn: $store.settings.titleCleanup.foldCommonAffix)
                CardPreview(settings: store.settings)
                    .frame(height: 220)
            }
            Section("背景与动画") {
                LabeledContent("遮罩深度") {
                    Slider(value: $store.settings.appearance.dimOpacity, in: 0...0.9)
                }
                Picker("减少动态效果", selection: $store.settings.appearance.reduceMotion) {
                    Text("跟随系统").tag(ReduceMotionMode.system)
                    Text("开").tag(ReduceMotionMode.on)
                    Text("关").tag(ReduceMotionMode.off)
                }
            }
        }
    }
}

/// 预览背景：模拟覆盖层的遮罩底色，随外观切换。
private final class CardPreviewBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(OverlayColors.dynamic(dark: NSColor(white: 0.1, alpha: 1), light: NSColor(white: 0.9, alpha: 1)))
    }
}

/// 标题样式的实时预览：直接复用覆盖层的卡片视图，外观与覆盖层一致（跟随"覆盖层主题"设置）。
private struct CardPreview: NSViewRepresentable {
    let settings: AppSettings

    func makeNSView(context: Context) -> NSView {
        CardPreviewBackground()
    }

    func updateNSView(_ container: NSView, context: Context) {
        container.appearance = settings.appearance.overlayTheme.appearance
        container.subviews.forEach { $0.removeFromSuperview() }
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = AppInfo(pid: pid, bundleID: nil, name: "Xcode")
        let samples = [
            "WindowDeck — OverlayContentView.swift — Xcode",
            String(localized: "WindowDeck — 一个很长很长的窗口标题，用来查看换行与截断的效果.swift — Xcode"),
        ]
        let titles = TitleFormatter.format(titles: samples, appName: app.name, cleanup: settings.titleCleanup)
        let width: CGFloat = 300
        for (index, title) in titles.enumerated() {
            let window = WindowInfo(id: CGWindowID(index + 1), pid: pid, title: samples[index], frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
            let card = CardView(window: window, app: app, title: title, style: .deck, settings: settings)
            card.frame = NSRect(x: 16 + CGFloat(index) * (width + 16), y: 16, width: width, height: 188)
            card.isHovered = index == 0
            card.setThumbnail(nil, animated: false)
            container.addSubview(card)
        }
    }
}

// MARK: 牌堆 / 当前应用 / 红绿灯

private struct DeckSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledContent("后层露出内容 \(Int(store.settings.deck.contentPeek)) pt") {
                    Slider(value: $store.settings.deck.contentPeek, in: DeckSettings.contentPeekRange, step: 4)
                }
                Stepper("最多堆叠 \(store.settings.deck.maxStackDepth) 层", value: $store.settings.deck.maxStackDepth, in: DeckSettings.maxStackDepthRange)
                Toggle("悬停牌堆时展开", isOn: $store.settings.deck.expandOnHover)
                Toggle("显示没有窗口的应用", isOn: $store.settings.deck.showAppsWithoutWindows)
            } footer: {
                Text("同一应用的窗口叠成一摞，最近使用的在最前。每层后面的卡片露出\"标题 + 一截窗口内容\"，标题字号越大，露出的部分越高。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExposeSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("已收起的窗口放在底部条带", isOn: $store.settings.expose.showMinimizedStrip)
                Toggle("其他桌面的窗口单独分组", isOn: $store.settings.expose.groupOtherSpaces)
            } footer: {
                Text("在当前应用视图中按 ⇥ / ⇧⇥ 切换到其他应用的窗口。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TrafficLightSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("显示时机", selection: $store.settings.trafficLights.visibility) {
                    Text("悬停时").tag(TrafficLightVisibility.onHover)
                    Text("始终").tag(TrafficLightVisibility.always)
                    Text("从不").tag(TrafficLightVisibility.never)
                }
                Toggle("关闭（红）", isOn: $store.settings.trafficLights.showClose)
                Toggle("收起（黄）", isOn: $store.settings.trafficLights.showMinimize)
                Toggle("全屏 / 缩放（绿）", isOn: $store.settings.trafficLights.showGreen)
                Picker("绿灯行为", selection: $store.settings.trafficLights.greenAction) {
                    Text("全屏").tag(GreenAction.fullscreen)
                    Text("缩放").tag(GreenAction.zoom)
                }
                Picker("关闭确认", selection: $store.settings.trafficLights.closeConfirmation) {
                    Text("直接关闭").tag(CloseConfirmation.none)
                    Text("按住 ⌥ 才关闭").tag(CloseConfirmation.optionKey)
                    Text("再点一次确认").tag(CloseConfirmation.clickTwice)
                }
            }
            Section {
                Toggle("关闭 / 收起后自动收起覆盖层", isOn: $store.settings.dismissAfterAction)
            } footer: {
                Text("默认不收起，方便连续整理多个窗口。快捷键：⌘W 关闭、⌘M 收起选中的窗口。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: 过滤

private struct FilterSettingsView: View {
    @Bindable var store: SettingsStore
    private let runningState = State(initialValue: [NSRunningApplication]())

    private var running: [NSRunningApplication] {
        get { runningState.wrappedValue }
        nonmutating set { runningState.wrappedValue = newValue }
    }

    var body: some View {
        Form {
            Section {
                Toggle("显示已收起的窗口", isOn: $store.settings.showMinimized)
                Toggle("显示已隐藏应用的窗口", isOn: $store.settings.showHiddenApps)
                Toggle("显示其他桌面的窗口", isOn: $store.settings.showWindowsFromOtherSpaces)
                Toggle("包含菜单栏工具类应用的窗口", isOn: $store.settings.includeAccessoryApps)
                Picker("多显示器", selection: $store.settings.multiDisplay) {
                    Text("每块屏幕显示本屏窗口").tag(MultiDisplayMode.perScreen)
                    Text("全部集中到鼠标所在屏幕").tag(MultiDisplayMode.allOnMouseScreen)
                }
            }
            Section("排除的应用") {
                ForEach(running, id: \.processIdentifier) { app in
                    if let bundleID = app.bundleIdentifier {
                        Toggle(isOn: excludedBinding(bundleID)) {
                            HStack {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                Text(app.localizedName ?? bundleID)
                            }
                        }
                    }
                }
                ForEach(notRunningExcluded, id: \.self) { bundleID in
                    Toggle(bundleID, isOn: excludedBinding(bundleID))
                }
            }
        }
        .onAppear {
            running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }

    private var notRunningExcluded: [String] {
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        return store.settings.excludedBundleIDs.filter { !runningIDs.contains($0) }
    }

    private func excludedBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.excludedBundleIDs.contains(bundleID) },
            set: { excluded in
                store.update { s in
                    s.excludedBundleIDs.removeAll { $0 == bundleID }
                    if excluded { s.excludedBundleIDs.append(bundleID) }
                }
            }
        )
    }
}

// MARK: 权限与诊断

private struct DiagnosticsView: View {
    let app: AppDelegate
    @Bindable var store: SettingsStore
    private let messageState = State(initialValue: String?.none)

    private var message: String? {
        get { messageState.wrappedValue }
        nonmutating set { messageState.wrappedValue = newValue }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section("权限") {
                    PermissionRow(
                        title: String(localized: "辅助功能"),
                        detail: String(localized: "必需：读取与操作窗口"),
                        granted: PermissionService.isAccessibilityTrusted,
                        action: {
                            PermissionService.requestAccessibility()
                            PermissionService.openAccessibilitySettings()
                        }
                    )
                    PermissionRow(
                        title: String(localized: "屏幕录制"),
                        detail: String(localized: "显示缩略图时需要；授权后需重新启动"),
                        granted: PermissionService.isScreenRecordingGranted,
                        action: {
                            PermissionService.requestScreenRecording()
                            PermissionService.openScreenRecordingSettings()
                        }
                    )
                    HStack {
                        Spacer()
                        Button("重新启动 WindowDeck") { PermissionService.relaunch() }
                    }
                }
                Section("系统能力") {
                    ForEach(app.capabilities.items) { item in
                        HStack(alignment: .top) {
                            Image(systemName: item.available ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.available ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(item.name)
                                if !item.available {
                                    Text("降级：\(item.fallback)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    let d = app.gesture.diagnostics
                    LabeledContent("触控设备", value: String(localized: "\(d.deviceCount) 个") + (app.gesture.isRunning ? "" : String(localized: "（未启动）")))
                    LabeledContent("已收到触控帧", value: "\(d.framesReceived)")
                    LabeledContent("当前手指数", value: "\(d.fingerCount)")
                    LabeledContent("原始数据", value: d.rawSample.isEmpty ? "—" : d.rawSample)
                        .font(.system(.body, design: .monospaced))
                    let conflict = GestureConflictStatus.detect(fingers: store.settings.gesture.fingers)
                    let on = String(localized: "开")
                    let off = String(localized: "关")
                    let swipe = conflict.verticalSwipeValue.map(String.init) ?? String(localized: "未设置")
                    let missionControl = conflict.missionControlGestureEnabled ? on : off
                    let appExpose = conflict.appExposeGestureEnabled ? on : off
                    let drag = conflict.threeFingerDrag ? on : off
                    LabeledContent("系统偏好", value: String(localized: "垂直轻扫=\(swipe) 调度中心=\(missionControl) App Exposé=\(appExpose) 三指拖移=\(drag)"))
                } header: {
                    Text("手势诊断")
                } footer: {
                    Text("把手指放在触控板上，\"当前手指数\"应随之变化；x / y 应在 0–1 之间变化。若不变化，说明当前系统上触控数据格式与预期不符。")
                        .foregroundStyle(.secondary)
                }
                Section("配置") {
                    HStack {
                        Button("导出配置…", action: exportSettings)
                        Button("导入配置…", action: importSettings)
                        Button("导出诊断信息…", action: exportDiagnostics)
                        Spacer()
                        Button("恢复默认设置", role: .destructive) { store.resetToDefaults() }
                    }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WindowDeck-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url)
            message = String(localized: "已导出到 \(url.path)")
        } catch {
            message = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importData(Data(contentsOf: url))
            message = String(localized: "已导入")
        } catch {
            message = String(localized: "导入失败：\(error.localizedDescription)")
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WindowDeck-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines: [String] = []
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append(String(localized: "辅助功能=\(String(PermissionService.isAccessibilityTrusted)) 屏幕录制=\(String(PermissionService.isScreenRecordingGranted))"))
        for item in app.capabilities.items { lines.append("\(item.name): \(item.available)") }
        let d = app.gesture.diagnostics
        lines.append("touch devices=\(d.deviceCount) frames=\(d.framesReceived) sample=\(d.rawSample)")
        let snapshot = app.catalog.snapshot()
        // 不导出窗口标题，只导出数量。
        lines.append("apps=\(snapshot.apps.count) windows=\(snapshot.windows.count)")
        if let data = try? store.exportData(), let json = String(data: data, encoding: .utf8) {
            lines.append("settings:\n\(json)")
        }
        lines.append("logs:\n" + Log.exportCurrentProcessLogs())
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            message = String(localized: "已导出到 \(url.path)")
        } catch {
            message = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("已授权").foregroundStyle(.secondary)
            } else {
                Button("去授权", action: action)
            }
        }
    }
}
