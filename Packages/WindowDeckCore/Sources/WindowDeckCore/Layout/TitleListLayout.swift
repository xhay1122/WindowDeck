import CoreGraphics
import Foundation

/// "仅标题"模式：每个应用一张"头部 + 标题列表"的卡片，瀑布流多列排布。
public struct TitleListGroup: Hashable, Sendable {
    public var appID: pid_t
    public var windowIDs: [CGWindowID]

    public init(appID: pid_t, windowIDs: [CGWindowID]) {
        self.appID = appID
        self.windowIDs = windowIDs
    }
}

public struct TitleListLayoutInput: Sendable {
    public var groups: [TitleListGroup]
    public var bounds: CGRect
    public var rowHeight: CGFloat
    public var headerHeight: CGFloat
    public var padding: CGFloat
    public var spacing: CGFloat
    public var minColumnWidth: CGFloat
    public var maxColumnWidth: CGFloat

    public init(
        groups: [TitleListGroup],
        bounds: CGRect,
        rowHeight: CGFloat,
        headerHeight: CGFloat = 36,
        padding: CGFloat = 10,
        spacing: CGFloat = 24,
        minColumnWidth: CGFloat = 320,
        maxColumnWidth: CGFloat = 560
    ) {
        self.groups = groups
        self.bounds = bounds
        self.rowHeight = rowHeight
        self.headerHeight = headerHeight
        self.padding = padding
        self.spacing = spacing
        self.minColumnWidth = minColumnWidth
        self.maxColumnWidth = maxColumnWidth
    }
}

public struct TitleListGroupFrame: Hashable, Sendable {
    public var appID: pid_t
    public var frame: CGRect
    public var headerFrame: CGRect
    public var rows: [CGWindowID: CGRect]
}

public struct TitleListLayoutResult: Sendable {
    public var groups: [TitleListGroupFrame]
    public var contentSize: CGSize
    public var needsScrolling: Bool

    public static let empty = TitleListLayoutResult(groups: [], contentSize: .zero, needsScrolling: false)
}

public enum TitleListLayout {
    public static func compute(_ input: TitleListLayoutInput) -> TitleListLayoutResult {
        guard !input.groups.isEmpty, input.bounds.width > 0 else { return .empty }

        func height(of group: TitleListGroup) -> CGFloat {
            input.headerHeight + input.rowHeight * CGFloat(group.windowIDs.count) + input.padding * 2
        }

        let maxColumns = max(1, Int((input.bounds.width + input.spacing) / (input.minColumnWidth + input.spacing)))
        let totalHeight = input.groups.reduce(0) { $0 + height(of: $1) + input.spacing }
        // 列数：内容能放进一屏时尽量少列（每列更宽），否则用满可用列数。
        var columns = maxColumns
        for c in 1...maxColumns where totalHeight / CGFloat(c) <= input.bounds.height {
            columns = c
            break
        }
        columns = min(columns, input.groups.count)

        let rawWidth = (input.bounds.width - input.spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let columnWidth = min(rawWidth, input.maxColumnWidth)
        let gridWidth = columnWidth * CGFloat(columns) + input.spacing * CGFloat(columns - 1)
        let originX = input.bounds.minX + (input.bounds.width - gridWidth) / 2

        var columnHeights = Array(repeating: CGFloat(0), count: columns)
        var placed: [(column: Int, y: CGFloat, group: TitleListGroup, height: CGFloat)] = []
        for group in input.groups {
            let column = columnHeights.indices.min { columnHeights[$0] < columnHeights[$1] } ?? 0
            let h = height(of: group)
            placed.append((column, columnHeights[column], group, h))
            columnHeights[column] += h + input.spacing
        }
        let contentHeight = max(0, (columnHeights.max() ?? 0) - input.spacing)
        let needsScrolling = contentHeight > input.bounds.height
        let originY = input.bounds.minY + (needsScrolling ? 0 : (input.bounds.height - contentHeight) / 2)

        let groups = placed.map { item -> TitleListGroupFrame in
            let x = originX + CGFloat(item.column) * (columnWidth + input.spacing)
            let frame = CGRect(x: x.rounded(), y: (originY + item.y).rounded(), width: columnWidth.rounded(), height: item.height)
            let header = CGRect(x: frame.minX, y: frame.minY + input.padding, width: frame.width, height: input.headerHeight)
            var rows: [CGWindowID: CGRect] = [:]
            for (index, id) in item.group.windowIDs.enumerated() {
                rows[id] = CGRect(
                    x: frame.minX,
                    y: header.maxY + input.rowHeight * CGFloat(index),
                    width: frame.width,
                    height: input.rowHeight
                )
            }
            return TitleListGroupFrame(appID: item.group.appID, frame: frame, headerFrame: header, rows: rows)
        }
        return TitleListLayoutResult(
            groups: groups,
            contentSize: CGSize(width: input.bounds.width, height: contentHeight),
            needsScrolling: needsScrolling
        )
    }
}
