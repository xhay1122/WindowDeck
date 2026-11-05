import AppKit
import SwiftUI
import WindowDeckCore

/// 首次启动引导：辅助功能（必需）→ 屏幕录制（可跳过）→ 手势冲突说明。
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: () -> Void

    init(app: AppDelegate, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "欢迎使用 WindowDeck")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let view = OnboardingView(app: app, store: app.settingsStore) { [weak self] in
            self?.close()
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onFinish()
    }
}

private struct OnboardingView: View {
    let app: AppDelegate
    @Bindable var store: SettingsStore
    let done: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let accessibility = PermissionService.isAccessibilityTrusted
            let screen = PermissionService.isScreenRecordingGranted
            let conflict = GestureConflictStatus.detect(fingers: store.settings.gesture.fingers)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 36)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("WindowDeck").font(.title.bold())
                        Text("三指上滑：按应用把窗口叠成牌堆；三指下滑：列出当前应用的窗口。")
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                step(1, title: "辅助功能权限（必需）", done: accessibility) {
                    Text("用于读取窗口列表、聚焦 / 关闭 / 收起窗口。在系统设置中打开 WindowDeck 的开关，授权后这里会自动变为已完成。")
                    if !accessibility {
                        Button("打开授权") {
                            PermissionService.requestAccessibility()
                            PermissionService.openAccessibilitySettings()
                        }
                    }
                }
                step(2, title: "屏幕录制权限（显示缩略图）", done: screen || !store.settings.showThumbnails) {
                    Text("用于截取窗口缩略图。授权后需要重新启动 WindowDeck；系统可能会定期再次确认。不授权也可以使用\"仅标题\"模式。")
                    if !screen, store.settings.showThumbnails {
                        HStack {
                            Button("打开授权") {
                                PermissionService.requestScreenRecording()
                                PermissionService.openScreenRecordingSettings()
                            }
                            Button("已授权，重新启动") { PermissionService.relaunch() }
                            Button("跳过，使用仅标题模式") { store.settings.showThumbnails = false }
                        }
                    }
                }
                step(3, title: "关闭系统的调度中心手势", done: !app.capabilities.gesture || !(conflict.hasConflict || conflict.dragConflict)) {
                    if app.capabilities.gesture {
                        Text(conflict.summary)
                        if conflict.hasConflict || conflict.dragConflict {
                            Text("在\"触控板 → 更多手势\"中把\"调度中心\"和\"App Exposé\"关闭（或改为四指）。之后仍可用 ⌃↑ / ⌃↓ 打开系统自带的调度中心。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("打开触控板设置") { PermissionService.openTrackpadSettings() }
                        }
                    } else {
                        Text("当前系统上无法读取触控板数据，可以在设置中配置快捷键来打开 WindowDeck。")
                    }
                }
                Spacer()
                HStack {
                    Button("打开设置…") { app.showSettings() }
                    Spacer()
                    Button("完成") { done() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!accessibility)
                }
            }
            .padding(24)
            .frame(width: 600, height: 620)
        }
    }

    @ViewBuilder
    private func step(_ index: Int, title: LocalizedStringKey, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(index)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
