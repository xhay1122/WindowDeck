import CoreGraphics
import Foundation

public struct DeckItem: Hashable, Sendable {
    public var appID: pid_t
    /// 按 MRU 排序，第一个是最前面（最近使用）的卡片。
    public var windowIDs: [CGWindowID]

    public init(appID: pid_t, windowIDs: [CGWindowID]) {
        self.appID = appID
        self.windowIDs = windowIDs
    }
}

public struct DeckLayoutInput: Sendable {
    public var decks: [DeckItem]
    public var bounds: CGRect
    public var titleBandHeight: CGFloat
    /// 后层卡片在标题区之外露出的内容高度。
    public var contentPeek: CGFloat
    public var maxStackDepth: Int
    /// 牌堆下方"图标 + 应用名"一行的高度。
    public var headerHeight: CGFloat
    /// 卡片高宽比（高 / 宽），默认 10:16。
    public var cardAspect: CGFloat
    public var spacing: CGFloat
    /// 每深一层，左右各收窄的宽度。
    public var layerInset: CGFloat
    /// 小于该宽度时改为纵向滚动。
    public var minCardWidth: CGFloat
    /// 应用很少时避免卡片过大。
    public var maxCardWidth: CGFloat

    public init(
        decks: [DeckItem],
        bounds: CGRect,
        titleBandHeight: CGFloat,
        contentPeek: CGFloat,
        maxStackDepth: Int,
        headerHeight: CGFloat = 28,
        cardAspect: CGFloat = 10.0 / 16.0,
        spacing: CGFloat = 32,
        layerInset: CGFloat = 8,
        minCardWidth: CGFloat = 180,
        maxCardWidth: CGFloat = 560
    ) {
        self.decks = decks
        self.bounds = bounds
        self.titleBandHeight = titleBandHeight
        self.contentPeek = contentPeek
        self.maxStackDepth = maxStackDepth
        self.headerHeight = headerHeight
        self.cardAspect = cardAspect
        self.spacing = spacing
        self.layerInset = layerInset
        self.minCardWidth = minCardWidth
        self.maxCardWidth = maxCardWidth
    }

    var peek: CGFloat { titleBandHeight + contentPeek }
}

public struct DeckCardFrame: Hashable, Sendable {
    public var windowID: CGWindowID
    /// 卡片完整尺寸（后层卡片大部分被前层遮住）。
    public var frame: CGRect
    /// 0 = 最前。
    public var depth: Int
    /// 卡片未被遮挡、可见可点的部分。
    public var visibleFrame: CGRect
}

public struct DeckFrame: Hashable, Sendable {
    public var appID: pid_t
    /// 牌堆单元格。
    public var cellFrame: CGRect
    /// 牌堆实际占用区域（卡片 + 应用标题行）。
    public var stackFrame: CGRect
    public var headerFrame: CGRect
    /// 只包含可见层，顺序为 depth 0…n。
    public var cards: [DeckCardFrame]
    /// 超出 maxStackDepth 而未显示的窗口数。
    public var overflowCount: Int
}

public struct DeckLayoutResult: Sendable {
    public var decks: [DeckFrame]
    /// 网格内容本身的尺寸（不含 bounds 之外的边距），高度可能超过 bounds（需要纵向滚动）。
    public var contentSize: CGSize
    public var columns: Int
    public var cardSize: CGSize

    public var needsScrolling: Bool = false

    public static let empty = DeckLayoutResult(decks: [], contentSize: .zero, columns: 0, cardSize: .zero)
}

/// Deck 视图：每个应用一个牌堆，牌堆排成网格。
public enum DeckLayout {
    public static func compute(_ input: DeckLayoutInput) -> DeckLayoutResult {
        let count = input.decks.count
        guard count > 0, input.bounds.width > 0, input.bounds.height > 0 else { return .empty }

        let depth = stackDepth(input)
        let extra = input.peek * CGFloat(depth - 1)
        let minCardHeight = input.titleBandHeight + 24

        var best: (columns: Int, card: CGSize, cell: CGSize)?
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellW = (input.bounds.width - input.spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellH = (input.bounds.height - input.spacing * CGFloat(rows - 1)) / CGFloat(rows)
            guard cellW > 0, cellH > 0 else { continue }
            var cardW = min(cellW, input.maxCardWidth)
            var cardH = cardW * input.cardAspect
            if cardH + extra + input.headerHeight > cellH {
                cardH = cellH - extra - input.headerHeight
                cardW = cardH / input.cardAspect
            }
            guard cardH >= minCardHeight, cardW >= input.minCardWidth else { continue }
            let area = cardW * cardH
            if best == nil || area > best!.card.width * best!.card.height + 0.5 {
                best = (columns, CGSize(width: cardW, height: cardH), CGSize(width: cellW, height: cellH))
            }
        }

        if let best {
            return place(input: input, columns: best.columns, card: best.card, cell: best.cell, depth: depth, scrolling: false)
        }
        // 放不下：固定最小卡片尺寸，纵向滚动。
        let cardW = input.minCardWidth
        let cardH = max(cardW * input.cardAspect, minCardHeight)
        let columns = max(1, Int((input.bounds.width + input.spacing) / (cardW + input.spacing)))
        let cellW = (input.bounds.width - input.spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = cardH + extra + input.headerHeight
        return place(
            input: input,
            columns: min(columns, count),
            card: CGSize(width: min(cardW, cellW), height: cardH),
            cell: CGSize(width: cellW, height: cellH),
            depth: depth,
            scrolling: true
        )
    }

    static func stackDepth(_ input: DeckLayoutInput) -> Int {
        let maxWindows = input.decks.map(\.windowIDs.count).max() ?? 1
        return max(1, min(input.maxStackDepth, maxWindows))
    }

    static func place(input: DeckLayoutInput, columns: Int, card: CGSize, cell: CGSize, depth: Int, scrolling: Bool) -> DeckLayoutResult {
        let count = input.decks.count
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let peek = input.peek
        let extra = peek * CGFloat(depth - 1)
        let contentHeight = cell.height * CGFloat(rows) + input.spacing * CGFloat(rows - 1)
        // 不需要滚动时，整个网格在 bounds 中垂直居中。
        let originY = scrolling ? input.bounds.minY : input.bounds.minY + max(0, (input.bounds.height - contentHeight) / 2)
        let stackHeight = card.height + extra + input.headerHeight

        var decks: [DeckFrame] = []
        decks.reserveCapacity(count)
        for (index, deck) in input.decks.enumerated() {
            let row = index / columns
            let column = index % columns
            // 最后一行不满时水平居中。
            let itemsInRow = row == rows - 1 ? count - row * columns : columns
            let rowWidth = cell.width * CGFloat(itemsInRow) + input.spacing * CGFloat(itemsInRow - 1)
            let rowOriginX = input.bounds.minX + (input.bounds.width - rowWidth) / 2
            let cellFrame = CGRect(
                x: rowOriginX + CGFloat(column) * (cell.width + input.spacing),
                y: originY + CGFloat(row) * (cell.height + input.spacing),
                width: cell.width,
                height: cell.height
            )
            let stackTop = cellFrame.minY + max(0, (cell.height - stackHeight) / 2)
            // 所有牌堆的最前卡片对齐，窗口少的牌堆上方留空。
            let frontY = stackTop + extra
            let cardX = cellFrame.minX + (cell.width - card.width) / 2

            let visible = min(deck.windowIDs.count, depth)
            var cards: [DeckCardFrame] = []
            for layer in 0..<visible {
                let inset = min(input.layerInset * CGFloat(layer), card.width / 4)
                let frame = CGRect(
                    x: (cardX + inset).rounded(),
                    y: (frontY - peek * CGFloat(layer)).rounded(),
                    width: (card.width - inset * 2).rounded(),
                    height: card.height.rounded()
                )
                let visibleFrame = layer == 0
                    ? frame
                    : CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(peek, frame.height))
                cards.append(DeckCardFrame(windowID: deck.windowIDs[layer], frame: frame, depth: layer, visibleFrame: visibleFrame))
            }
            let topY = cards.last?.frame.minY ?? frontY
            let headerFrame = CGRect(
                x: cellFrame.minX,
                y: (frontY + card.height).rounded(),
                width: cell.width,
                height: input.headerHeight
            )
            let stackFrame = CGRect(x: cardX, y: topY, width: card.width, height: headerFrame.maxY - topY)
            decks.append(DeckFrame(
                appID: deck.appID,
                cellFrame: cellFrame,
                stackFrame: stackFrame,
                headerFrame: headerFrame,
                cards: cards,
                overflowCount: max(0, deck.windowIDs.count - visible)
            ))
        }

        var result = DeckLayoutResult(
            decks: decks,
            contentSize: CGSize(width: input.bounds.width, height: contentHeight),
            columns: columns,
            cardSize: card
        )
        result.needsScrolling = scrolling && contentHeight > input.bounds.height
        return result
    }

    /// 悬停展开的区域：单元格放大 `factor` 倍，限制在 bounds 内。
    public static func expansionRegion(cell: CGRect, bounds: CGRect, factor: CGFloat = 1.6) -> CGRect {
        let w = min(cell.width * factor, bounds.width)
        let h = min(cell.height * factor, bounds.height)
        var x = cell.midX - w / 2
        var y = cell.midY - h / 2
        x = min(max(x, bounds.minX), bounds.maxX - w)
        y = min(max(y, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
