import CoreGraphics

/// 所有布局都在"左上角原点、y 向下"的坐标系中计算，App 层用 flipped 视图直接使用结果。
public struct LayoutItem: Hashable, Sendable {
    public var id: CGWindowID
    /// 窗口原始尺寸（pt）。
    public var size: CGSize

    public init(id: CGWindowID, size: CGSize) {
        self.id = id
        self.size = size
    }
}

public struct ExposeLayoutInput: Sendable {
    /// 按 MRU 排序。
    public var items: [LayoutItem]
    public var bounds: CGRect
    /// 每张卡片额外的标题区高度（不随缩放变化）。
    public var titleBandHeight: CGFloat
    public var spacing: CGFloat
    /// 不放大超过原尺寸。
    public var maxScale: CGFloat
    public var minScale: CGFloat
    /// 限制最大行数（例如"已收起"条带只允许 1 行）。
    public var maxRows: Int?

    public init(
        items: [LayoutItem],
        bounds: CGRect,
        titleBandHeight: CGFloat,
        spacing: CGFloat = 24,
        maxScale: CGFloat = 1,
        minScale: CGFloat = 0.02,
        maxRows: Int? = nil
    ) {
        self.items = items
        self.bounds = bounds
        self.titleBandHeight = titleBandHeight
        self.spacing = spacing
        self.maxScale = maxScale
        self.minScale = minScale
        self.maxRows = maxRows
    }
}

public struct ExposeLayoutResult: Sendable {
    /// 卡片整体（缩略图 + 标题区）。
    public var frames: [CGWindowID: CGRect]
    public var scale: CGFloat
    public var rows: Int

    public static let empty = ExposeLayoutResult(frames: [:], scale: 0, rows: 0)
}

/// 行分配算法：保持宽高比，选择让整体缩放最大的行数。
public enum ExposeLayout {
    public static func compute(_ input: ExposeLayoutInput) -> ExposeLayoutResult {
        let items = input.items.map { item in
            LayoutItem(id: item.id, size: CGSize(width: max(item.size.width, 1), height: max(item.size.height, 1)))
        }
        guard !items.isEmpty, input.bounds.width > 0, input.bounds.height > 0 else { return .empty }

        let maxRows = min(items.count, max(input.maxRows ?? items.count, 1))
        var best: (rows: [[LayoutItem]], scale: CGFloat)?
        for rowCount in 1...maxRows {
            let rows = partition(items, into: rowCount)
            let scale = fittingScale(rows: rows, input: input)
            // 严格大于：缩放相同时保留更少的行。
            if best == nil || scale > best!.scale + 0.0001 {
                best = (rows, scale)
            }
        }
        guard let best else { return .empty }
        let scale = min(max(best.scale, input.minScale), input.maxScale)
        return place(rows: best.rows, scale: scale, input: input)
    }

    /// 按 MRU 顺序贪心分行，使各行原始宽度和尽量均衡。
    static func partition(_ items: [LayoutItem], into rowCount: Int) -> [[LayoutItem]] {
        guard rowCount > 1 else { return [items] }
        let total = items.reduce(0) { $0 + $1.size.width }
        let target = total / CGFloat(rowCount)
        var rows: [[LayoutItem]] = [[]]
        var width: CGFloat = 0
        for (index, item) in items.enumerated() {
            let remainingItems = items.count - index
            let remainingRows = rowCount - rows.count
            let shouldBreak = !rows[rows.count - 1].isEmpty
                && remainingRows > 0
                && (width + item.size.width / 2 > target || remainingItems <= remainingRows)
            if shouldBreak {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append(item)
            width += item.size.width
        }
        return rows.filter { !$0.isEmpty }
    }

    static func fittingScale(rows: [[LayoutItem]], input: ExposeLayoutInput) -> CGFloat {
        let rowCount = CGFloat(rows.count)
        let availableHeight = input.bounds.height - input.spacing * (rowCount - 1) - input.titleBandHeight * rowCount
        guard availableHeight > 0 else { return 0 }
        let totalRowHeight = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) }
        var scale = availableHeight / totalRowHeight
        for row in rows {
            let availableWidth = input.bounds.width - input.spacing * CGFloat(row.count - 1)
            guard availableWidth > 0 else { return 0 }
            let rowWidth = row.reduce(0) { $0 + $1.size.width }
            scale = min(scale, availableWidth / rowWidth)
        }
        return min(scale, input.maxScale)
    }

    static func place(rows: [[LayoutItem]], scale: CGFloat, input: ExposeLayoutInput) -> ExposeLayoutResult {
        let rowHeights = rows.map { ($0.map(\.size.height).max() ?? 0) * scale + input.titleBandHeight }
        let totalHeight = rowHeights.reduce(0, +) + input.spacing * CGFloat(rows.count - 1)
        var y = input.bounds.minY + max(0, (input.bounds.height - totalHeight) / 2)
        var frames: [CGWindowID: CGRect] = [:]
        for (rowIndex, row) in rows.enumerated() {
            let rowWidth = row.reduce(0) { $0 + $1.size.width * scale } + input.spacing * CGFloat(row.count - 1)
            var x = input.bounds.minX + max(0, (input.bounds.width - rowWidth) / 2)
            let rowHeight = rowHeights[rowIndex]
            for item in row {
                let w = (item.size.width * scale).rounded()
                let h = (item.size.height * scale).rounded() + input.titleBandHeight
                let cardY = y + (rowHeight - h) / 2
                frames[item.id] = CGRect(x: x.rounded(), y: cardY.rounded(), width: w, height: h)
                x += item.size.width * scale + input.spacing
            }
            y += rowHeight + input.spacing
        }
        return ExposeLayoutResult(frames: frames, scale: scale, rows: rows.count)
    }
}
