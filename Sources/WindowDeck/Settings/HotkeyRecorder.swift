import AppKit
import Carbon.HIToolbox
import SwiftUI
import WindowDeckCore

/// 快捷键录制控件：点击后按下组合键；Esc 取消，Delete 清除。
struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    var conflict: Bool
    var onRecordingChange: (Bool) -> Void

    // CommandLineTools 工具链缺少 SwiftUI 宏插件（新版 SDK 中 @State 是宏），这里直接使用 State 属性包装器类型。
    private let recordingState = State(initialValue: false)
    /// 监听器句柄必须跨视图重建保持，否则无法移除。
    private let monitorState = State(initialValue: MonitorBox())

    private var monitor: MonitorBox { monitorState.wrappedValue }

    private var recording: Bool {
        get { recordingState.wrappedValue }
        nonmutating set { recordingState.wrappedValue = newValue }
    }

    final class MonitorBox {
        var token: Any?
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(label)
                    .frame(minWidth: 150)
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
            }
            if combo != nil, !recording {
                Button("清除") { combo = nil }
            }
            if conflict {
                Label("已被占用", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("注册失败，可能被其他应用占用，请换一个组合")
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return String(localized: "请按下快捷键…") }
        return combo.map(KeyComboFormatter.string(for:)) ?? String(localized: "点击录制")
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        onRecordingChange(true)
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = KeyComboFormatter.carbonModifiers(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            let keyCode = Int(event.keyCode)
            if modifiers == 0, keyCode == kVK_Escape {
                stop()
            } else if modifiers == 0, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
                combo = nil
                stop()
            } else if KeyComboFormatter.isValid(keyCode: keyCode, modifiers: modifiers) {
                combo = KeyCombo(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let token = monitor.token {
            NSEvent.removeMonitor(token)
            monitor.token = nil
        }
        if recording {
            recording = false
            onRecordingChange(false)
        }
    }
}
