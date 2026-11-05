import Foundation

/// 解码时容忍缺失字段：缺失或类型不符时回退到默认值，便于配置升级。
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }
}
