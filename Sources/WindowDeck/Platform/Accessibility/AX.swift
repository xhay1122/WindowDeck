import ApplicationServices
import CoreGraphics
import Foundation

/// AXUIElement 不是 Sendable。用这个包装在队列之间传递，约束：只在所属应用的 AX 队列上调用 AX 函数。
struct AXRef: @unchecked Sendable, Hashable {
    let element: AXUIElement

    static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// AX 调用的薄封装。所有函数都是同步调用，必须在后台队列上执行（不在主线程直接调用）。
enum AX {
    static let fullScreenAttribute = "AXFullScreen"

    static func cfBool(_ value: Bool) -> CFBoolean {
        value ? kCFBooleanTrue : kCFBooleanFalse
    }

    static func setTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value, error)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute).value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copy(element, attribute).value as? NSNumber)?.boolValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute).value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> (elements: [AXUIElement], error: AXError) {
        let (value, error) = copy(element, attribute)
        guard error == .success, let array = value as? [AnyObject] else { return ([], error) }
        let result = array.compactMap { item -> AXUIElement? in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
        return (result, error)
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute).value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copy(element, attribute).value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute), let size = size(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    /// 窗口按钮（关闭 / 缩放 / 最小化）是否存在且可用。
    static func buttonEnabled(_ window: AXUIElement, _ attribute: String) -> Bool {
        guard let button = element(window, attribute) else { return false }
        return bool(button, kAXEnabledAttribute) ?? true
    }
}

/// 所有 AXObserver 的 run loop source 挂在这条专用线程上，回调里只做转发。
final class AXObserverThread: Thread, @unchecked Sendable {
    static let shared: AXObserverThread = {
        let thread = AXObserverThread()
        thread.name = "com.windowdeck.ax-observer"
        thread.qualityOfService = .userInitiated
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // 保证 run loop 在没有 source 时也不会立即退出。
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        ready.signal()
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    func add(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CFRunLoopWakeUp(runLoop)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }
}
