import AppKit
import ServiceManagement
import WindowDeckCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    let capabilities = CapabilityRegistry.probe()
    let thumbnails = ThumbnailService()
    let gesture = GestureService()
    private(set) var hotkeys: HotkeyService!
    private(set) var catalog: WindowCatalog!
    private(set) var overlay: OverlayController!

    private var menuBar: MenuBarController!
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var servicesStarted = false
    private var permissionTimer: Timer?
    private(set) var gesturePaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = settingsStore.settings.appearance.theme.appearance
        _ = AppLanguage.atLaunch
        hotkeys = HotkeyService()
        catalog = WindowCatalog(settingsStore: settingsStore, capabilities: capabilities)
        overlay = OverlayController(catalog: catalog, thumbnails: thumbnails, settingsStore: settingsStore)
        menuBar = MenuBarController(app: self)

        settingsStore.observe { [weak self] new, old in
            self?.settingsDidChange(new, old: old)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.screensDidChange() }
        }

        // 快捷键不依赖辅助功能权限，先注册；默认没有快捷键。
        hotkeys.onTrigger = { [weak self] slot in
            self?.overlay.trigger(slot == .deck ? .deck : .expose, source: .hotkey)
        }
        hotkeys.apply(settingsStore.settings.hotkeys)

        if PermissionService.isAccessibilityTrusted {
            startServices()
        } else {
            waitForAccessibility()
        }
        if !settingsStore.settings.hasCompletedOnboarding || !PermissionService.isAccessibilityTrusted {
            showOnboarding()
        }
        Log.app.info("launched; capabilities windowID=\(self.capabilities.windowID) spaces=\(self.capabilities.spaces) gesture=\(self.capabilities.gesture)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: 服务

    private func waitForAccessibility() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if PermissionService.isAccessibilityTrusted {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.startServices()
                    self.menuBar.refresh()
                }
            }
        }
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        let settings = settingsStore.settings

        thumbnails.quality = settings.thumbnailQuality
        thumbnails.isEnabled = settings.showThumbnails
        thumbnails.onUpdate = { [weak self] id, image in
            self?.overlay.thumbnailUpdated(id, image: image)
        }

        catalog.onChange = { [weak self] in
            self?.overlay.catalogDidChange()
        }
        catalog.onWindowLostFocus = { [weak self] window in
            guard let self, self.settingsStore.settings.showThumbnails else { return }
            self.thumbnails.prewarm(window)
        }
        catalog.start()

        gesture.onSwipe = { [weak self] direction in
            guard let self, !self.gesturePaused else { return }
            self.overlay.trigger(direction == .up ? .deck : .expose, source: .gesture)
        }
        gesture.configure(settings.gesture)

        // 预热缩略图缓存，保证第一次打开就有内容。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.prewarmAllThumbnails() }
        }
    }

    private func prewarmAllThumbnails() {
        guard settingsStore.settings.showThumbnails else { return }
        let snapshot = catalog.snapshot()
        thumbnails.refresh(snapshot.apps.flatMap { snapshot.windows(of: $0) })
    }

    private func settingsDidChange(_ new: AppSettings, old: AppSettings) {
        if new.gesture != old.gesture {
            gesture.configure(new.gesture)
            if gesturePaused { gesture.setPaused(true) }
        }
        if new.hotkeys != old.hotkeys {
            hotkeys.apply(new.hotkeys)
        }
        if new.showThumbnails != old.showThumbnails || new.thumbnailQuality != old.thumbnailQuality {
            thumbnails.quality = new.thumbnailQuality
            thumbnails.isEnabled = new.showThumbnails
            if new.showThumbnails { prewarmAllThumbnails() }
        }
        if new.excludedBundleIDs != old.excludedBundleIDs || new.includeAccessoryApps != old.includeAccessoryApps {
            catalog.syncTrackedApps()
        }
        if new.showWindowsFromOtherSpaces != old.showWindowsFromOtherSpaces {
            catalog.refreshAll()
        }
        if new.launchAtLogin != old.launchAtLogin {
            setLaunchAtLogin(new.launchAtLogin)
        }
        if new.appearance.theme != old.appearance.theme {
            // 设置窗口、引导窗口与覆盖层都继承 NSApp.appearance；nil 表示跟随系统。
            NSApp.appearance = new.appearance.theme.appearance
        }
        menuBar.refresh()
        overlay.catalogDidChange()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 菜单动作

    func showDeck() { overlay.trigger(.deck, source: .menu) }
    func showExpose() { overlay.trigger(.expose, source: .menu) }

    func toggleGesturePaused() {
        gesturePaused.toggle()
        gesture.setPaused(gesturePaused)
        menuBar.refresh()
    }

    func showSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(app: self)
        }
        settingsWindow?.show(tab: tab)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(app: self) { [weak self] in
                self?.settingsStore.update { $0.hasCompletedOnboarding = true }
                self?.onboardingWindow = nil
            }
        }
        onboardingWindow?.show()
    }

    var gestureConflict: GestureConflictStatus {
        GestureConflictStatus.detect(fingers: settingsStore.settings.gesture.fingers)
    }
}
