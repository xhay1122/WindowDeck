import ApplicationServices
import CoreGraphics
import Foundation

/// SkyLight（WindowServer 客户端）私有 API。
enum SkyLight {
    typealias ConnectionID = Int32

    typealias MainConnectionIDFn = @convention(c) () -> ConnectionID
    typealias CopyManagedDisplaySpacesFn = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindowsFn = @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias GetActiveSpaceFn = @convention(c) (ConnectionID) -> UInt64
    typealias SetFrontProcessWithOptionsFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecordToFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> CGError
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    static let mainConnectionIDFn = PrivateSymbols.resolve(PrivateSymbols.skyLight, "SLSMainConnectionID", as: MainConnectionIDFn.self)
    static let copyManagedDisplaySpacesFn = PrivateSymbols.resolve(PrivateSymbols.skyLight, "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    static let copySpacesForWindowsFn = PrivateSymbols.resolve(PrivateSymbols.skyLight, "SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    static let getActiveSpaceFn = PrivateSymbols.resolve(PrivateSymbols.skyLight, "SLSGetActiveSpace", as: GetActiveSpaceFn.self)
    static let setFrontProcessWithOptionsFn = PrivateSymbols.resolve(PrivateSymbols.skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptionsFn.self)
    static let postEventRecordToFn = PrivateSymbols.resolve(PrivateSymbols.skyLight, "SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    /// 公开但已废弃的 Carbon 函数，同样运行时解析，避免废弃告警与将来被移除时链接失败。
    static let getProcessForPIDFn = PrivateSymbols.resolve(PrivateSymbols.defaultHandle, "GetProcessForPID", as: GetProcessForPIDFn.self)

    static var connection: ConnectionID? {
        guard let fn = mainConnectionIDFn else { return nil }
        let cid = fn()
        return cid > 0 ? cid : nil
    }

    // MARK: Spaces

    /// 每个显示器当前的 Space ID。
    static func currentSpaceIDs() -> Set<UInt64> {
        guard let cid = connection, let fn = copyManagedDisplaySpacesFn,
              let displays = fn(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result = Set<UInt64>()
        for display in displays {
            if let current = display["Current Space"] as? [String: Any], let id = spaceID(current) {
                result.insert(id)
            }
        }
        return result
    }

    /// 窗口所在的 Space；不受 WindowServer 管理的窗口（例如部分辅助窗口）返回空。
    static func spaceIDs(for windowID: CGWindowID) -> [UInt64]? {
        guard let cid = connection, let fn = copySpacesForWindowsFn else { return nil }
        let ids = [NSNumber(value: windowID)] as CFArray
        // 0x7 = 全部类型的 Space（当前 / 其他 / 全屏）。
        guard let spaces = fn(cid, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return spaces.map(\.uint64Value)
    }

    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        if let id = dict["id64"] as? NSNumber { return id.uint64Value }
        if let id = dict["ManagedSpaceID"] as? NSNumber { return id.uint64Value }
        return nil
    }

    // MARK: 精确聚焦

    static var supportsPreciseFocus: Bool {
        setFrontProcessWithOptionsFn != nil && postEventRecordToFn != nil && getProcessForPIDFn != nil
    }

    /// 把指定进程置前并把指定窗口设为 key window。
    /// 做法来自公开的逆向资料：先以"用户触发"模式置前进程，再向进程投递两条合成的窗口事件记录。
    @discardableResult
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront = setFrontProcessWithOptionsFn,
              let post = postEventRecordToFn,
              let getPSN = getProcessForPIDFn else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        // kCPSUserGenerated
        guard setFront(&psn, windowID, 0x200) == .success else { return false }

        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: windowID) { raw in
            for (i, b) in raw.enumerated() { bytes[0x3C + i] = b }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        bytes[0x08] = 0x01
        _ = post(&psn, bytes)
        bytes[0x08] = 0x02
        _ = post(&psn, bytes)
        return true
    }
}
