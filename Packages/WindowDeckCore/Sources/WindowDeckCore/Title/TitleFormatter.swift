import Foundation

/// 格式化后的标题：`prefix` / `suffix` 是同一应用窗口间的公共部分（弱化显示），`core` 是区分度最高的部分。
public struct FormattedTitle: Equatable, Sendable {
    public var prefix: String
    public var core: String
    public var suffix: String
    /// 原标题为空，`core` 是占位文本。
    public var isPlaceholder: Bool

    public init(prefix: String = "", core: String, suffix: String = "", isPlaceholder: Bool = false) {
        self.prefix = prefix
        self.core = core
        self.suffix = suffix
        self.isPlaceholder = isPlaceholder
    }

    public var full: String { prefix + core + suffix }
}

public enum TitleFormatter {
    /// 常见的标题分隔符，按优先级排列。
    static let separators = [" — ", " – ", " - ", " | ", " · ", " • ", " ― "]
    /// 公共前后缀只能在这些字符处断开，避免把单词切成两半。
    static let boundaryCharacters: Set<Character> = [" ", "-", "—", "–", "|", "·", "•", "/", "\\", ":", "：", "(", ")", "[", "]", "_"]
    /// 公共部分至少这么长才折叠，避免对 "a" 一类无意义前缀做弱化。
    static let minimumAffixLength = 3

    /// 规范化：去掉换行与首尾空白。
    public static func normalize(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 去掉 " — AppName" / " - AppName" 一类后缀；去掉后为空则保持原样。
    public static func stripAppSuffix(_ title: String, appName: String) -> String {
        let name = appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return title }
        for separator in separators {
            let tail = separator + name
            if title.count > tail.count,
               title.lowercased().hasSuffix(tail.lowercased()) {
                let stripped = String(title.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { return stripped }
            }
        }
        return title
    }

    /// 空标题的占位文本，`index` 从 1 开始。
    /// 文案从主 Bundle 的 Localizable.strings 读取（App 内为 WindowDeck.app）；没有对应翻译时使用中文原文。
    public static func placeholder(appName: String, index: Int) -> String {
        String(format: NSLocalizedString("%@ · 窗口 %ld", bundle: .main, comment: "空标题窗口的占位文本：应用名 · 窗口序号"), appName, index)
    }

    /// 对同一应用的一组窗口标题做清洗与公共前后缀折叠。返回值与输入一一对应。
    public static func format(titles: [String], appName: String, cleanup: TitleCleanup) -> [FormattedTitle] {
        let cleaned: [String] = titles.map { raw in
            let n = normalize(raw)
            return cleanup.stripAppSuffix ? stripAppSuffix(n, appName: appName) : n
        }

        var result: [FormattedTitle] = []
        result.reserveCapacity(cleaned.count)
        var placeholderIndex = 0
        for title in cleaned {
            if title.isEmpty {
                placeholderIndex += 1
                result.append(FormattedTitle(core: placeholder(appName: appName, index: placeholderIndex), isPlaceholder: true))
            } else {
                result.append(FormattedTitle(core: title))
            }
        }

        guard cleanup.foldCommonAffix else { return result }

        let realIndices = result.indices.filter { !result[$0].isPlaceholder }
        guard realIndices.count >= 2 else { return result }
        let chars = realIndices.map { Array(result[$0].core) }

        let prefixLength = commonPrefixLength(chars)
        let reversed = chars.map { Array($0.dropFirst(prefixLength).reversed()) }
        let suffixLength = commonPrefixLength(reversed)

        guard prefixLength > 0 || suffixLength > 0 else { return result }
        for (k, index) in realIndices.enumerated() {
            let c = chars[k]
            let core = c[prefixLength..<(c.count - suffixLength)]
            guard !core.allSatisfy({ $0 == " " }) else { continue }
            result[index] = FormattedTitle(
                prefix: String(c[0..<prefixLength]),
                core: String(core),
                suffix: String(c[(c.count - suffixLength)...])
            )
        }
        return result
    }

    /// 所有序列的公共前缀长度，回退到分隔字符处；保证每个序列在前缀之后至少还剩 1 个字符。
    /// 对反转后的序列调用即可得到公共后缀（此时要求后缀以分隔字符开头）。
    static func commonPrefixLength(_ sequences: [[Character]]) -> Int {
        guard let first = sequences.first else { return 0 }
        let limit = (sequences.map(\.count).min() ?? 0) - 1
        guard limit > 0 else { return 0 }
        var length = 0
        while length < limit, sequences.allSatisfy({ $0[length] == first[length] }) {
            length += 1
        }
        // 回退到分隔字符：断点处的最后一个公共字符必须是分隔字符。
        while length > 0, !boundaryCharacters.contains(first[length - 1]) {
            length -= 1
        }
        return length >= minimumAffixLength ? length : 0
    }

    /// 按字符数截断，`keep` 为保留的字符数（不含省略号）。
    public static func truncate(_ text: String, keeping keep: Int, mode: Truncation) -> String {
        let chars = Array(text)
        guard chars.count > keep else { return text }
        guard keep > 0 else { return "…" }
        switch mode {
        case .tail:
            return String(chars[0..<keep]) + "…"
        case .head:
            return "…" + String(chars[(chars.count - keep)...])
        case .middle:
            let head = (keep + 1) / 2
            let tail = keep - head
            return String(chars[0..<head]) + "…" + String(chars[(chars.count - tail)...])
        }
    }
}
