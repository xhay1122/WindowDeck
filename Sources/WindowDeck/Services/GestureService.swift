import AppKit
import Foundation
import os
import WindowDeckCore

/// 触控回调与主线程共享的状态。回调在私有线程上执行，只做轻量计算。
private struct GestureSharedState: Sendable {
    var enabled = false
    var config = SwipeRecognizerConfig()
    /// 每个设备一个识别器，避免内置触控板与外接触控板的帧交错。
    var recognizers: [UInt: SwipeRecognizer] = [:]
    var handler: (@Sendable (SwipeDirection) -> Void)?
    var framesReceived: UInt64 = 0
    var lastFingerCount = 0
    var lastRawSample: String = ""
}

private let gestureShared = OSAllocatedUnfairLock(initialState: GestureSharedState())

private func contactFrameCallback(_ device: Multitouch.DeviceRef?, _ touches: UnsafeMutableRawPointer?, _ count: Int32, _ timestamp: Double, _: Int32) -> Int32 {
    let raw = Multitouch.readTouches(touches, count: count)
    let active = raw.filter { $0.state == Multitouch.touchingState }.map { TouchPoint(id: $0.identifier, x: $0.x, y: $0.y) }
    let key = UInt(bitPattern: device)
    let (direction, handler) = gestureShared.withLock { state -> (SwipeDirection?, (@Sendable (SwipeDirection) -> Void)?) in
        state.framesReceived &+= 1
        state.lastFingerCount = active.count
        if let first = raw.first {
            state.lastRawSample = String(format: "id=%d state=%d x=%.3f y=%.3f n=%d", first.identifier, first.state, first.x, first.y, raw.count)
        }
        guard state.enabled else { return (nil, nil) }
        var recognizer = state.recognizers[key] ?? SwipeRecognizer(config: state.config)
        let result = recognizer.process(TouchFrame(timestamp: timestamp, touches: active))
        state.recognizers[key] = recognizer
        return (result, state.handler)
    }
    if let direction, let handler {
        handler(direction)
    }
    return 0
}

/// 打开触控设备，识别三指（可配置）上下滑。
@MainActor
final class GestureService {
    struct Diagnostics: Sendable {
        var deviceCount: Int
        var framesReceived: UInt64
        var fingerCount: Int
        var rawSample: String
    }

    var onSwipe: ((SwipeDirection) -> Void)?

    private var deviceList: CFArray?
    private var devices: [Multitouch.DeviceRef] = []
    private var pollTimer: Timer?
    private var wakeToken: NSObjectProtocol?
    private(set) var isRunning = false

    var isAvailable: Bool { Multitouch.isAvailable }

    func configure(_ settings: GestureSettings) {
        var config = SwipeRecognizerConfig()
        config.fingers = settings.fingers
        config.distanceThreshold = settings.distanceThreshold
        let finalConfig = config
        gestureShared.withLock { state in
            state.config = finalConfig
            state.recognizers.removeAll()
        }
        if settings.enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard isAvailable, !isRunning else { return }
        let handler: @Sendable (SwipeDirection) -> Void = { [weak self] direction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(direction) }
            }
        }
        gestureShared.withLock { state in
            state.handler = handler
            state.enabled = true
        }
        openDevices()
        isRunning = true
        // 设备热插拔：每 5s 轻量检查设备数量；睡眠唤醒后重建。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDevices() }
        }
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartDevices() }
        }
        Log.gesture.info("gesture started with \(self.devices.count) devices")
    }

    func stop() {
        guard isRunning else { return }
        gestureShared.withLock { state in
            state.enabled = false
            state.handler = nil
        }
        closeDevices()
        pollTimer?.invalidate()
        pollTimer = nil
        if let wakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeToken)
        }
        wakeToken = nil
        isRunning = false
    }

    /// 暂停识别但保留设备（例如菜单中的"暂停手势"）。
    func setPaused(_ paused: Bool) {
        let running = isRunning
        gestureShared.withLock { state in
            state.enabled = !paused && running
            state.recognizers.removeAll()
        }
    }

    var diagnostics: Diagnostics {
        let deviceCount = devices.count
        return gestureShared.withLock { state in
            Diagnostics(deviceCount: deviceCount, framesReceived: state.framesReceived, fingerCount: state.lastFingerCount, rawSample: state.lastRawSample)
        }
    }

    private func deliver(_ direction: SwipeDirection) {
        // 锁屏时不响应。
        guard !Self.isScreenLocked else { return }
        Log.gesture.debug("swipe \(direction == .up ? "up" : "down", privacy: .public)")
        onSwipe?(direction)
    }

    private func openDevices() {
        guard let list = Multitouch.deviceList(), let register = Multitouch.registerFn, let startFn = Multitouch.startFn else { return }
        deviceList = list
        devices = Multitouch.devices(in: list)
        for device in devices {
            register(device, contactFrameCallback)
            _ = startFn(device, 0)
        }
    }

    private func closeDevices() {
        for device in devices {
            Multitouch.unregisterFn?(device, contactFrameCallback)
            _ = Multitouch.stopFn?(device)
        }
        devices.removeAll()
        deviceList = nil
        gestureShared.withLock { $0.recognizers.removeAll() }
    }

    private func restartDevices() {
        guard isRunning else { return }
        closeDevices()
        openDevices()
    }

    private func checkDevices() {
        guard let list = Multitouch.deviceList() else { return }
        if CFArrayGetCount(list) != devices.count {
            Log.gesture.info("touch device count changed, reopening")
            restartDevices()
        }
    }

    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// 检测系统手势是否占用了同样的手势。只读取偏好，不修改系统设置。
struct GestureConflictStatus: Sendable, Equatable {
    var fingers: Int
    /// 系统对 N 指垂直轻扫的设置（2 = 系统调度中心使用）。
    var verticalSwipeValue: Int?
    var missionControlGestureEnabled: Bool
    var appExposeGestureEnabled: Bool
    var threeFingerDrag: Bool

    var hasConflict: Bool {
        (verticalSwipeValue ?? 2) == 2 && (missionControlGestureEnabled || appExposeGestureEnabled)
    }

    var dragConflict: Bool { fingers == 3 && threeFingerDrag }

    var summary: String {
        if hasConflict {
            return String(localized: "系统的调度中心 / App Exposé 手势仍在使用\(fingers)指上下滑，需要在系统设置 → 触控板 → 更多手势中关闭。")
        }
        if dragConflict {
            return String(localized: "已开启\"三指拖移\"，三指滑动会被当作拖拽。建议改用四指，或关闭三指拖移。")
        }
        return String(localized: "没有检测到手势冲突。")
    }

    static func detect(fingers: Int) -> GestureConflictStatus {
        let trackpadDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        func trackpadValue(_ key: String) -> Any? {
            for domain in trackpadDomains {
                if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) { return value }
            }
            return nil
        }
        func dockBool(_ key: String) -> Bool {
            (CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? NSNumber)?.boolValue ?? true
        }
        let key = fingers == 4 ? "TrackpadFourFingerVertSwipeGesture" : "TrackpadThreeFingerVertSwipeGesture"
        return GestureConflictStatus(
            fingers: fingers,
            verticalSwipeValue: (trackpadValue(key) as? NSNumber)?.intValue,
            missionControlGestureEnabled: dockBool("showMissionControlGestureEnabled"),
            appExposeGestureEnabled: dockBool("showAppExposeGestureEnabled"),
            threeFingerDrag: (trackpadValue("TrackpadThreeFingerDrag") as? NSNumber)?.boolValue ?? false
        )
    }
}
