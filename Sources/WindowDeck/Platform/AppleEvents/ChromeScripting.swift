import AppKit
import CoreServices
import Foundation
import WindowDeckCore

/// Chrome（Chromium 系）脚本字典的 Apple Event 封装，四字符码取自 Chrome 的 `scripting.sdef`。
/// 直接拼装 Apple Event 而不用 `NSAppleScript`：后者要求在主线程使用，而 Apple Event 需要等待目标应用回复。
/// 所有方法都是同步的，只能在调用方的后台串行队列上调用。
enum ChromeScripting {
    enum Failure: Error, Equatable {
        /// 用户拒绝了"自动化"权限（errAEEventNotPermitted）。
        case notPermitted
        /// 尚未询问过用户（errAEEventWouldRequireUserConsent）。
        case needsConsent
        /// 目标应用未运行（procNotFound）。
        case notRunning
        /// 超时或其他错误。
        case failed(OSStatus)
        /// 回复格式不符合预期（例如读取期间标签页发生变化，各属性列表长度不一致）。
        case malformedReply

        init(status: OSStatus) {
            switch status {
            case OSStatus(errAEEventNotPermitted): self = .notPermitted
            case OSStatus(errAEEventWouldRequireUserConsent): self = .needsConsent
            case OSStatus(procNotFound): self = .notRunning
            default: self = .failed(status)
            }
        }
    }

    static let timeout: TimeInterval = 1.5

    // MARK: 权限

    /// 查询（可选：询问用户）是否允许向目标应用发送 Apple Events。
    /// `askUserIfNeeded = true` 时会阻塞到用户在系统弹窗中做出选择。
    static func determinePermission(pid: pid_t, askUserIfNeeded: Bool) -> Result<Void, Failure> {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let desc = target.aeDesc else { return .failure(.failed(OSStatus(paramErr))) }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askUserIfNeeded)
        return status == noErr ? .success(()) : .failure(Failure(status: status))
    }

    // MARK: 读取

    /// 读取全部窗口与标签页。属性按列表批量读取（每个属性一次往返），读取期间若窗口 / 标签页数量变化会返回 `.malformedReply`。
    static func fetchWindows(pid: pid_t) -> Result<[BrowserWindowTabs], Failure> {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let windows = Spec.every(Code.window)
        let tabs = Spec.every(Code.tab, of: windows)
        do {
            let windowIDs = try list(get(Spec.property(Code.id, of: windows), target: target))
            let count = windowIDs.count
            guard count > 0 else { return .success([]) }
            let names = try list(get(Spec.property(Code.name, of: windows), target: target))
            let bounds = try list(get(Spec.property(Code.bounds, of: windows), target: target))
            let modes = try list(get(Spec.property(Code.mode, of: windows), target: target))
            let activeIndexes = try list(get(Spec.property(Code.activeTabIndex, of: windows), target: target))
            let minimized = try list(get(Spec.property(Code.minimized, of: windows), target: target))
            let tabIDs = try list(get(Spec.property(Code.id, of: tabs), target: target))
            let tabTitles = try list(get(Spec.property(Code.name, of: tabs), target: target))
            let tabURLs = try list(get(Spec.property(Code.url, of: tabs), target: target))
            guard [names.count, bounds.count, modes.count, activeIndexes.count, minimized.count, tabIDs.count, tabTitles.count, tabURLs.count]
                .allSatisfy({ $0 == count }) else { return .failure(.malformedReply) }

            var result: [BrowserWindowTabs] = []
            for i in 0..<count {
                let ids = list(tabIDs[i])
                let titles = list(tabTitles[i])
                let urls = list(tabURLs[i])
                guard ids.count == titles.count, ids.count == urls.count else { return .failure(.malformedReply) }
                let windowTabs = (0..<ids.count).map { t in
                    BrowserTab(id: objectID(ids[t]), title: titles[t].stringValue ?? "", url: urls[t].stringValue ?? "")
                }
                // 脚本里的 active tab index 从 1 开始。
                let active = Int(activeIndexes[i].int32Value) - 1
                result.append(BrowserWindowTabs(
                    id: objectID(windowIDs[i]),
                    title: names[i].stringValue ?? "",
                    bounds: rect(bounds[i]),
                    isIncognito: modes[i].stringValue == "incognito",
                    isMinimized: minimized[i].booleanValue,
                    activeTabIndex: windowTabs.indices.contains(active) ? active : nil,
                    tabs: windowTabs
                ))
            }
            return .success(result)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed(OSStatus(errAEEventFailed)))
        }
    }

    // MARK: 操作

    /// 切换到指定标签页：先按标签 id 重新定位下标（读取之后标签可能被拖动 / 关闭），再设置 `active tab index`。
    /// `raiseWindow` 为 true 时同时把窗口设为浏览器的最前窗口（找不到对应系统窗口时的退化方案）。
    static func activateTab(_ tabID: ScriptObjectID, inWindow windowID: ScriptObjectID, pid: pid_t, raiseWindow: Bool) -> Result<Void, Failure> {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let window = Spec.window(id: windowID)
        do {
            guard let index = try indexOfTab(tabID, in: window, target: target) else { return .failure(.malformedReply) }
            try set(Spec.property(Code.activeTabIndex, of: window), to: NSAppleEventDescriptor(int32: Int32(index + 1)), target: target)
            if raiseWindow {
                try set(Spec.property(Code.index, of: window), to: NSAppleEventDescriptor(int32: 1), target: target)
                try? set(Spec.property(Code.minimized, of: window), to: NSAppleEventDescriptor(boolean: false), target: target)
            }
            return .success(())
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed(OSStatus(errAEEventFailed)))
        }
    }

    static func closeTab(_ tabID: ScriptObjectID, inWindow windowID: ScriptObjectID, pid: pid_t) -> Result<Void, Failure> {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let window = Spec.window(id: windowID)
        do {
            guard let index = try indexOfTab(tabID, in: window, target: target) else { return .failure(.malformedReply) }
            let event = makeEvent(Code.coreSuite, Code.close, target: target)
            event.setParam(Spec.element(Code.tab, index: index + 1, of: window), forKeyword: Code.directObject)
            _ = try send(event)
            return .success(())
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.failed(OSStatus(errAEEventFailed)))
        }
    }

    private static func indexOfTab(_ tabID: ScriptObjectID, in window: NSAppleEventDescriptor, target: NSAppleEventDescriptor) throws -> Int? {
        let ids = try list(get(Spec.property(Code.id, of: Spec.every(Code.tab, of: window)), target: target))
        return ids.firstIndex { objectID($0) == tabID }
    }

    // MARK: Apple Event 收发

    private static func makeEvent(_ eventClass: AEEventClass, _ eventID: AEEventID, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass,
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            // neverInteract：不在覆盖层显示期间弹出授权框；授权由调用方显式发起。
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch let error as NSError {
            throw Failure(status: OSStatus(truncatingIfNeeded: error.code))
        }
        if let number = reply.paramDescriptor(forKeyword: Code.errorNumber)?.int32Value, number != 0 {
            throw Failure(status: OSStatus(number))
        }
        return reply
    }

    private static func get(_ specifier: NSAppleEventDescriptor, target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = makeEvent(Code.coreSuite, Code.getData, target: target)
        event.setParam(specifier, forKeyword: Code.directObject)
        guard let result = try send(event).paramDescriptor(forKeyword: Code.directObject) else { throw Failure.malformedReply }
        return result
    }

    private static func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, target: NSAppleEventDescriptor) throws {
        let event = makeEvent(Code.coreSuite, Code.setData, target: target)
        event.setParam(specifier, forKeyword: Code.directObject)
        event.setParam(value, forKeyword: Code.data)
        _ = try send(event)
    }

    // MARK: 解析

    /// 列表描述符 → 数组；单个值视为只有一项的列表。
    private static func list(_ desc: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard desc.descriptorType == Code.typeList else { return [desc] }
        guard desc.numberOfItems > 0 else { return [] }
        return (1...desc.numberOfItems).compactMap { desc.atIndex($0) }
    }

    private static func objectID(_ desc: NSAppleEventDescriptor) -> ScriptObjectID {
        switch desc.descriptorType {
        case Code.typeSInt32, Code.typeSInt16, Code.typeSInt64, Code.typeUInt32:
            return .integer(Int(desc.int32Value))
        default:
            return .text(desc.stringValue ?? "")
        }
    }

    /// `bounds`：{left, top, right, bottom} 列表或 QuickDraw 矩形，坐标系与 AX 一致（左上角原点）。
    private static func rect(_ desc: NSAppleEventDescriptor) -> CGRect? {
        if desc.descriptorType == Code.typeQDRectangle {
            let data = desc.data
            guard data.count >= 8 else { return nil }
            let v = data.withUnsafeBytes { raw in (0..<4).map { CGFloat(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
            // QuickDraw Rect：top, left, bottom, right。
            return CGRect(x: v[1], y: v[0], width: v[3] - v[1], height: v[2] - v[0])
        }
        let items = list(desc)
        guard items.count == 4 else { return nil }
        let v = items.map { CGFloat($0.int32Value) }
        return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
    }

    // MARK: 对象说明符

    private enum Spec {
        static func every(_ cls: FourCharCode, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
            var all = Code.all
            let data = NSAppleEventDescriptor(descriptorType: Code.typeAbsoluteOrdinal, bytes: &all, length: MemoryLayout<FourCharCode>.size)
            return make(want: cls, form: Code.formAbsolutePosition, data: data ?? .null(), container: container)
        }

        static func element(_ cls: FourCharCode, index: Int, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            make(want: cls, form: Code.formAbsolutePosition, data: NSAppleEventDescriptor(int32: Int32(index)), container: container)
        }

        static func window(id: ScriptObjectID) -> NSAppleEventDescriptor {
            let data: NSAppleEventDescriptor = switch id {
            case let .integer(value): NSAppleEventDescriptor(int32: Int32(truncatingIfNeeded: value))
            case let .text(value): NSAppleEventDescriptor(string: value)
            }
            return make(want: Code.window, form: Code.formUniqueID, data: data, container: .null())
        }

        static func property(_ code: FourCharCode, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            make(want: Code.typeProperty, form: Code.formPropertyID, data: NSAppleEventDescriptor(typeCode: code), container: container)
        }

        private static func make(want: FourCharCode, form: FourCharCode, data: NSAppleEventDescriptor, container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: Code.desiredClass)
            record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: Code.keyForm)
            record.setDescriptor(data, forKeyword: Code.keyData)
            record.setDescriptor(container, forKeyword: Code.container)
            return record.coerce(toDescriptorType: Code.typeObjectSpecifier) ?? record
        }
    }

    // MARK: 四字符码

    private enum Code {
        static func fcc(_ s: String) -> FourCharCode {
            s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
        }

        // 事件
        static let coreSuite = fcc("core")
        static let getData = fcc("getd")
        static let setData = fcc("setd")
        static let close = fcc("clos")

        // 参数关键字
        static let directObject = fcc("----")
        static let data = fcc("data")
        static let errorNumber = fcc("errn")

        // 对象说明符
        static let desiredClass = fcc("want")
        static let keyForm = fcc("form")
        static let keyData = fcc("seld")
        static let container = fcc("from")
        static let formAbsolutePosition = fcc("indx")
        static let formPropertyID = fcc("prop")
        static let formUniqueID = fcc("ID  ")
        static let typeObjectSpecifier = fcc("obj ")
        static let typeProperty = fcc("prop")
        static let typeAbsoluteOrdinal = fcc("abso")
        static let all = fcc("all ")

        // 数据类型
        static let typeList = fcc("list")
        static let typeQDRectangle = fcc("qdrt")
        static let typeSInt16 = fcc("shor")
        static let typeSInt32 = fcc("long")
        static let typeSInt64 = fcc("comp")
        static let typeUInt32 = fcc("magn")

        // Chrome 脚本字典
        static let window = fcc("cwin")
        static let tab = fcc("CrTb")
        static let id = fcc("ID  ")
        static let name = fcc("pnam")
        static let bounds = fcc("pbnd")
        static let mode = fcc("mode")
        static let activeTabIndex = fcc("acTI")
        static let minimized = fcc("pmnd")
        static let index = fcc("pidx")
        static let url = fcc("URL ")
    }
}
