import Darwin
import Foundation

/// 私有符号统一在运行时通过 dlsym 解析，缺失时返回 nil，不在编译期链接私有框架。
enum PrivateSymbols {
    /// `RTLD_DEFAULT`：在已加载的所有镜像中查找。
    nonisolated(unsafe) static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    nonisolated(unsafe) static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated(unsafe) static let multitouch = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)

    static func resolve<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
