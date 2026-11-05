import AppKit
import Carbon.HIToolbox
import Foundation
import WindowDeckCore

/// 全局快捷键（Carbon RegisterEventHotKey）。默认不注册任何快捷键。
@MainActor
final class HotkeyService {
    enum Slot: UInt32, CaseIterable, Sendable {
        case deck = 1
        case expose = 2
    }

    var onTrigger: ((Slot) -> Void)?
    /// 注册失败（通常是被其他应用占用）的快捷键。
    private(set) var failedSlots: Set<Slot> = []

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var current = HotkeySettings()
    private var suspended = false

    fileprivate static weak var shared: HotkeyService?
    private static let signature: OSType = 0x5744_636B // "WDck"

    init() {
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)
        if status != noErr {
            Log.hotkey.error("InstallEventHandler failed: \(status)")
        }
    }

    func apply(_ settings: HotkeySettings) {
        current = settings
        guard !suspended else { return }
        register()
    }

    /// 录制快捷键期间暂停，避免触发。
    func setSuspended(_ value: Bool) {
        suspended = value
        if value {
            unregisterAll()
        } else {
            register()
        }
    }

    private func register() {
        unregisterAll()
        failedSlots.removeAll()
        for slot in Slot.allCases {
            guard let combo = slot == .deck ? current.deck : current.expose else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[slot] = ref
            } else {
                failedSlots.insert(slot)
                Log.hotkey.error("RegisterEventHotKey failed for slot \(slot.rawValue): \(status)")
            }
        }
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard let slot = Slot(rawValue: id) else { return }
        onTrigger?(slot)
    }
}

private func hotKeyEventHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotkeyService.shared?.fire(id) }
    }
    return noErr
}

/// 快捷键与 NSEvent / 显示文本之间的转换。
enum KeyComboFormatter {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    /// 没有修饰键时只允许功能键，避免普通按键被全局占用。
    static func isValid(keyCode: Int, modifiers: UInt32) -> Bool {
        let hasModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        return hasModifier || functionKeys[keyCode] != nil
    }

    static func string(for combo: KeyCombo) -> String {
        var s = ""
        if combo.carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if combo.carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if combo.carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if combo.carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(Int(combo.keyCode))
    }

    static func keyName(_ keyCode: Int) -> String {
        if let name = functionKeys[keyCode] ?? specialKeys[keyCode] { return name }
        return translate(keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// 按当前键盘布局把虚拟键码翻译成字符。
    private static func translate(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
