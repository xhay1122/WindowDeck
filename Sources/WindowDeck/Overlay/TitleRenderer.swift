import AppKit
import WindowDeckCore

/// 标题排版：在给定宽度和行数内放下标题。
/// 放不下时先把弱化的公共前后缀收成"…"，再按配置的截断方式截断区分度最高的部分。
@MainActor
enum TitleRenderer {
    struct Result {
        let text: NSAttributedString
        let isTruncated: Bool
    }

    static let horizontalPadding: CGFloat = 8

    static func font(for style: TitleStyle) -> NSFont {
        let weight: NSFont.Weight = switch style.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return NSFont.systemFont(ofSize: style.fontSize, weight: weight)
    }

    static func secondaryFont(for style: TitleStyle) -> NSFont {
        NSFont.systemFont(ofSize: max(style.fontSize * 0.82, 10), weight: .regular)
    }

    static func lineHeight(for style: TitleStyle) -> CGFloat {
        let layout = NSLayoutManager()
        return ceil(layout.defaultLineHeight(for: font(for: style)))
    }

    /// 标题区高度 = 行高 × 行数 + 上下内边距，参与布局计算，大字号不会被裁切。
    static func bandHeight(for style: TitleStyle) -> CGFloat {
        lineHeight(for: style) * CGFloat(style.maxLines) + CGFloat(TitleStyle.verticalPadding) * 2
    }

    static func render(_ title: FormattedTitle, appPrefix: String?, style: TitleStyle, width: CGFloat, alignment: NSTextAlignment) -> Result {
        let maxHeight = lineHeight(for: style) * CGFloat(style.maxLines) + 1
        let width = max(width, 20)

        func build(prefix: String, core: String, suffix: String) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byWordWrapping
            let main: [NSAttributedString.Key: Any] = [
                .font: font(for: style),
                .foregroundColor: OverlayColors.text(),
                .paragraphStyle: paragraph,
            ]
            let dim: [NSAttributedString.Key: Any] = [
                .font: secondaryFont(for: style),
                .foregroundColor: OverlayColors.text(alpha: 0.55),
                .paragraphStyle: paragraph,
            ]
            let s = NSMutableAttributedString()
            if let appPrefix, !appPrefix.isEmpty {
                s.append(NSAttributedString(string: appPrefix + " · ", attributes: dim))
            }
            if !prefix.isEmpty { s.append(NSAttributedString(string: prefix, attributes: dim)) }
            s.append(NSAttributedString(string: core, attributes: title.isPlaceholder ? dim.merging([.font: font(for: style)]) { $1 } : main))
            if !suffix.isEmpty { s.append(NSAttributedString(string: suffix, attributes: dim)) }
            return s
        }

        func fits(_ s: NSAttributedString) -> Bool {
            let rect = s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return ceil(rect.height) <= maxHeight
        }

        let full = build(prefix: title.prefix, core: title.core, suffix: title.suffix)
        if fits(full) { return Result(text: full, isTruncated: false) }

        // 1. 公共前后缀收起。
        let prefix = title.prefix.isEmpty ? "" : "…"
        let suffix = title.suffix.isEmpty ? "" : " …"
        let collapsed = build(prefix: prefix, core: title.core, suffix: suffix)
        if fits(collapsed) { return Result(text: collapsed, isTruncated: true) }

        // 2. 二分查找能放下的最多字符数。
        let count = title.core.count
        var low = 0
        var high = count
        var best = build(prefix: prefix, core: "…", suffix: "")
        while low <= high {
            let mid = (low + high) / 2
            let candidate = build(prefix: prefix, core: TitleFormatter.truncate(title.core, keeping: mid, mode: style.truncation), suffix: suffix)
            if fits(candidate) {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return Result(text: best, isTruncated: true)
    }
}
