import CoreFoundation
import Foundation
import WindowDeckCore

/// MultitouchSupport 私有框架：读取触控板原始触点。
enum Multitouch {
    typealias DeviceRef = UnsafeMutableRawPointer
    typealias ContactCallback = @convention(c) (DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    typealias RegisterFn = @convention(c) (DeviceRef, ContactCallback) -> Void
    typealias StartFn = @convention(c) (DeviceRef, Int32) -> Int32
    typealias StopFn = @convention(c) (DeviceRef) -> Int32
    typealias IsBuiltInFn = @convention(c) (DeviceRef) -> Bool

    static let createListFn = PrivateSymbols.resolve(PrivateSymbols.multitouch, "MTDeviceCreateList", as: CreateListFn.self)
    static let registerFn = PrivateSymbols.resolve(PrivateSymbols.multitouch, "MTRegisterContactFrameCallback", as: RegisterFn.self)
    static let unregisterFn = PrivateSymbols.resolve(PrivateSymbols.multitouch, "MTUnregisterContactFrameCallback", as: RegisterFn.self)
    static let startFn = PrivateSymbols.resolve(PrivateSymbols.multitouch, "MTDeviceStart", as: StartFn.self)
    static let stopFn = PrivateSymbols.resolve(PrivateSymbols.multitouch, "MTDeviceStop", as: StopFn.self)
    static let isBuiltInFn = PrivateSymbols.resolve(PrivateSymbols.multitouch, "MTDeviceIsBuiltIn", as: IsBuiltInFn.self)

    static var isAvailable: Bool {
        createListFn != nil && registerFn != nil && startFn != nil && stopFn != nil
    }

    /// 返回设备列表；数组本身需要由调用方持有，设备引用的生命周期跟随数组。
    static func deviceList() -> CFArray? {
        createListFn?()?.takeRetainedValue()
    }

    static func devices(in list: CFArray) -> [DeviceRef] {
        (0..<CFArrayGetCount(list)).compactMap { index in
            CFArrayGetValueAtIndex(list, index).map { UnsafeMutableRawPointer(mutating: $0) }
        }
    }

    // MARK: MTTouch 结构体

    /// 按社区逆向的 64 位布局读取：
    /// frame(Int32 @0) · timestamp(Double @8) · identifier(Int32 @16) · state(Int32 @20) ·
    /// fingerID(Int32 @24) · handID(Int32 @28) · normalized.position(Float×2 @32) · normalized.velocity(Float×2 @40) …
    /// 总长 96 字节。macOS 27 上的实际布局需在设备上用诊断页核对。
    enum Layout {
        static let stride = 96
        static let identifier = 16
        static let state = 20
        static let positionX = 32
        static let positionY = 36
    }

    /// 触点状态：4 = 接触中。
    static let touchingState: Int32 = 4

    struct RawTouch: Sendable {
        var identifier: Int32
        var state: Int32
        var x: Float
        var y: Float
    }

    static func readTouches(_ pointer: UnsafeMutableRawPointer?, count: Int32) -> [RawTouch] {
        guard let pointer, count > 0, count < 32 else { return [] }
        return (0..<Int(count)).map { i in
            let base = UnsafeRawPointer(pointer).advanced(by: i * Layout.stride)
            return RawTouch(
                identifier: base.loadUnaligned(fromByteOffset: Layout.identifier, as: Int32.self),
                state: base.loadUnaligned(fromByteOffset: Layout.state, as: Int32.self),
                x: base.loadUnaligned(fromByteOffset: Layout.positionX, as: Float.self),
                y: base.loadUnaligned(fromByteOffset: Layout.positionY, as: Float.self)
            )
        }
    }
}
