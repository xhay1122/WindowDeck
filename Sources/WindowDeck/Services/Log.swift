import Foundation
import OSLog

/// 分类日志。日志中不记录窗口内容；窗口标题只在 debug 级别输出。
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.windowdeck.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let gesture = Logger(subsystem: subsystem, category: "gesture")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")

    /// 导出本进程的日志（诊断用）。
    static func exportCurrentProcessLogs(since: Date = Date().addingTimeInterval(-3600)) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let entries = try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == subsystem }
            let formatter = ISO8601DateFormatter()
            return entries.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }.joined(separator: "\n")
        } catch {
            return String(localized: "无法读取日志：\(error.localizedDescription)")
        }
    }
}
