import AppKit
import WindowDeckCore

/// 菜单栏入口：显示牌堆 / 显示当前应用窗口 / 暂停手势 / 设置… / 权限状态 / 退出。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var app: AppDelegate?
    private let menu = NSMenu()

    /// 菜单栏模板图标（Support/Resources/MenuBarIcon.pdf，由 scripts/make-icon.sh 生成）。
    /// 未打包成 .app 运行时资源不存在，返回 nil，由调用方回退到 SF Symbol。
    private static let deckIcon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        image.size = NSSize(width: 18, height: 13)
        image.isTemplate = true
        image.accessibilityDescription = "WindowDeck"
        return image
    }()

    init(app: AppDelegate) {
        self.app = app
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    /// 有权限缺失或手势冲突时，菜单栏图标显示提示。
    func refresh() {
        guard let app else { return }
        let needsAttention = !PermissionService.isAccessibilityTrusted
            || (app.settingsStore.settings.gesture.enabled && app.capabilities.gesture && app.gestureConflict.hasConflict)
        statusItem.button?.image = needsAttention
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "WindowDeck")
            : Self.deckIcon ?? NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "WindowDeck")
        statusItem.button?.toolTip = needsAttention ? String(localized: "WindowDeck：需要处理权限或手势冲突") : "WindowDeck"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let app else { return }
        menu.removeAllItems()
        let settings = app.settingsStore.settings

        let deck = item("显示牌堆", #selector(showDeck))
        if let combo = settings.hotkeys.deck { deck.title += "    " + KeyComboFormatter.string(for: combo) }
        menu.addItem(deck)
        let expose = item("显示当前应用窗口", #selector(showExpose))
        if let combo = settings.hotkeys.expose { expose.title += "    " + KeyComboFormatter.string(for: combo) }
        menu.addItem(expose)
        menu.addItem(.separator())

        if settings.gesture.enabled, app.capabilities.gesture {
            let pause = item("暂停手势", #selector(togglePause))
            pause.state = app.gesturePaused ? .on : .off
            menu.addItem(pause)
            let conflict = app.gestureConflict
            if conflict.hasConflict || conflict.dragConflict {
                let warning = NSMenuItem(title: String(localized: "⚠︎ 手势冲突：系统手势仍然开启"), action: nil, keyEquivalent: "")
                warning.isEnabled = false
                menu.addItem(warning)
                menu.addItem(item("打开触控板设置…", #selector(openTrackpad)))
            }
            menu.addItem(.separator())
        } else if settings.gesture.enabled, !app.capabilities.gesture {
            let warning = NSMenuItem(title: String(localized: "手势不可用，请使用快捷键"), action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if !PermissionService.isAccessibilityTrusted {
            menu.addItem(item("⚠︎ 授予辅助功能权限…", #selector(openOnboarding)))
        }
        if settings.showThumbnails, !PermissionService.isScreenRecordingGranted {
            menu.addItem(item("授予屏幕录制权限（显示缩略图）…", #selector(openScreenRecording)))
        }

        let settingsItem = item("设置…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("权限与诊断…", #selector(openDiagnostics)))
        menu.addItem(.separator())
        let quit = item("退出 WindowDeck", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String.LocalizationValue, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // 菜单关闭后再触发覆盖层，避免菜单跟踪循环干扰键盘焦点。
    @objc private func showDeck() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.app?.showDeck() } }
    }

    @objc private func showExpose() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.app?.showExpose() } }
    }

    @objc private func togglePause() { app?.toggleGesturePaused() }
    @objc private func openTrackpad() { PermissionService.openTrackpadSettings() }
    @objc private func openOnboarding() { app?.showOnboarding() }

    @objc private func openScreenRecording() {
        PermissionService.requestScreenRecording()
        PermissionService.openScreenRecordingSettings()
    }

    @objc private func openSettings() { app?.showSettings() }
    @objc private func openDiagnostics() { app?.showSettings(tab: .diagnostics) }
    @objc private func quit() { NSApp.terminate(nil) }
}
