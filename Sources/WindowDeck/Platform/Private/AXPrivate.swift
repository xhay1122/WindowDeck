import ApplicationServices
import CoreGraphics
import Foundation

/// 辅助功能相关的私有符号（位于 HIServices，随 ApplicationServices 已加载）。
enum AXPrivate {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    static let getWindowFn = PrivateSymbols.resolve(PrivateSymbols.defaultHandle, "_AXUIElementGetWindow", as: GetWindowFn.self)
    static let createWithRemoteTokenFn = PrivateSymbols.resolve(PrivateSymbols.defaultHandle, "_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteTokenFn.self)

    /// AX 窗口元素 → CGWindowID。
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var id: CGWindowID = 0
        guard fn(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// 用远程令牌构造指定进程中的 AX 元素，用于拿到其他桌面上的窗口。
    /// 令牌 20 字节：pid(4) + 保留(4) + 魔数 "coco"(4) + 元素 ID(8)，格式未公开，可能随系统变化。
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let fn = createWithRemoteTokenFn else { return nil }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid.littleEndian, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636F_636F).littleEndian, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: elementID.littleEndian, toByteOffset: 12, as: UInt64.self)
        }
        return fn(token as CFData)?.takeRetainedValue()
    }
}
