import Foundation

/// 界面语言。通过本应用域内的 `AppleLanguages` 覆盖系统语言，与"系统设置 → 通用 → 语言与地区 → 应用程序"
/// 中的按应用设置是同一个键；重新启动后生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    private static let key = "AppleLanguages"

    private static var domainName: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    /// 只读取本应用域，避免把全局语言列表误认为应用设置。
    static var current: AppLanguage {
        guard let languages = UserDefaults.standard.persistentDomain(forName: domainName)?[key] as? [String],
              let first = languages.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// 启动时实际使用的语言设置，用于判断是否需要重新启动。
    static let atLaunch = current

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: Self.key)
        case .simplifiedChinese, .english: UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }
}
