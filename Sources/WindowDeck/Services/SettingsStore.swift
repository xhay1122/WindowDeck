import Foundation
import Observation
import WindowDeckCore

/// 配置读写：以 JSON 存到 UserDefaults，变更后通知各服务。
@MainActor
@Observable
final class SettingsStore {
    static let defaultsKey = "settings.v1"

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            for observer in observers.values { observer(settings, oldValue) }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: (AppSettings, AppSettings) -> Void] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                settings = try SettingsCodec.decode(data)
            } catch {
                Log.app.error("settings decode failed, using defaults: \(error.localizedDescription, privacy: .public)")
                settings = AppSettings()
            }
        } else {
            settings = AppSettings()
        }
    }

    /// 注册变更回调（新值, 旧值），返回的 token 用于注销。
    @discardableResult
    func observe(_ handler: @escaping (AppSettings, AppSettings) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    func resetToDefaults() {
        var fresh = AppSettings()
        fresh.hasCompletedOnboarding = settings.hasCompletedOnboarding
        settings = fresh
    }

    func exportData() throws -> Data {
        try SettingsCodec.encode(settings)
    }

    func importData(_ data: Data) throws {
        settings = try SettingsCodec.decode(data)
    }

    private func save() {
        do {
            defaults.set(try SettingsCodec.encode(settings), forKey: Self.defaultsKey)
        } catch {
            Log.app.error("settings encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
