import CoreGraphics
import Testing
@testable import WindowDeckCore

private let screen = CGRect(x: 40, y: 60, width: 1600, height: 900)

private func overlaps(_ rects: [CGRect]) -> Bool {
    for i in rects.indices {
        for j in rects.indices where j > i {
            if rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j].insetBy(dx: 0.5, dy: 0.5)) { return true }
        }
    }
    return false
}

private func contained(_ rect: CGRect, in bounds: CGRect) -> Bool {
    bounds.insetBy(dx: -1, dy: -1).contains(rect)
}

@Suite("DeckLayout")
struct DeckLayoutTests {
    func input(appWindowCounts: [Int], depth: Int = 5, titleBand: CGFloat = 48, peek: CGFloat = 36) -> DeckLayoutInput {
        var next: CGWindowID = 1
        let decks = appWindowCounts.enumerated().map { index, count -> DeckItem in
            let ids = (0..<count).map { _ -> CGWindowID in defer { next += 1 }; return next }
            return DeckItem(appID: pid_t(index + 100), windowIDs: ids)
        }
        return DeckLayoutInput(decks: decks, bounds: screen, titleBandHeight: titleBand, contentPeek: peek, maxStackDepth: depth)
    }

    @Test(arguments: [[1], [3, 1], [2, 2, 2, 1, 1, 4, 1], Array(repeating: 2, count: 20)])
    func decksStayInBoundsAndDoNotOverlap(_ counts: [Int]) {
        let result = DeckLayout.compute(input(appWindowCounts: counts))
        #expect(result.decks.count == counts.count)
        #expect(!result.needsScrolling)
        for deck in result.decks {
            #expect(contained(deck.stackFrame, in: screen))
            for card in deck.cards {
                #expect(contained(card.frame, in: screen))
            }
        }
        #expect(!overlaps(result.decks.map(\.stackFrame)))
    }

    @Test func manyAppsFallBackToScrolling() {
        let result = DeckLayout.compute(input(appWindowCounts: Array(repeating: 5, count: 50)))
        #expect(result.needsScrolling)
        #expect(result.cardSize.width >= 180 - 0.5)
        #expect(!overlaps(result.decks.map(\.stackFrame)))
        for deck in result.decks {
            #expect(deck.stackFrame.minX >= screen.minX - 1 && deck.stackFrame.maxX <= screen.maxX + 1)
        }
    }

    @Test func stackDepthIsCappedAndOverflowCounted() {
        let result = DeckLayout.compute(input(appWindowCounts: [9, 2], depth: 5))
        #expect(result.decks[0].cards.count == 5)
        #expect(result.decks[0].overflowCount == 4)
        #expect(result.decks[1].cards.count == 2)
        #expect(result.decks[1].overflowCount == 0)
    }

    @Test func backCardsPeekByTitleBandPlusContent() {
        let result = DeckLayout.compute(input(appWindowCounts: [3], titleBand: 50, peek: 30))
        let cards = result.decks[0].cards
        #expect(cards[0].frame.minY - cards[1].frame.minY == 80)
        #expect(cards[1].frame.minY - cards[2].frame.minY == 80)
        // 后层卡片逐层收窄。
        #expect(cards[1].frame.width < cards[0].frame.width)
        #expect(cards[1].visibleFrame.height == 80)
        // 最前卡片完全可见。
        #expect(cards[0].visibleFrame == cards[0].frame)
    }

    @Test func largeTitleShrinksCardsButKeepsThemInside() {
        let small = DeckLayout.compute(input(appWindowCounts: [4, 4, 4, 4, 4, 4], titleBand: 30))
        let large = DeckLayout.compute(input(appWindowCounts: [4, 4, 4, 4, 4, 4], titleBand: 110))
        #expect(large.cardSize.height < small.cardSize.height || large.columns != small.columns)
        for deck in large.decks {
            for card in deck.cards { #expect(card.frame.height >= 110 + 24 - 0.5) }
            #expect(contained(deck.stackFrame, in: screen) || large.needsScrolling)
        }
    }

    @Test func frontCardsAlignWithinRow() {
        let result = DeckLayout.compute(input(appWindowCounts: [1, 4, 2]))
        let rows = Dictionary(grouping: result.decks) { $0.cellFrame.minY }
        for (_, decks) in rows {
            let fronts = Set(decks.map { $0.cards[0].frame.minY })
            #expect(fronts.count == 1)
        }
    }

    @Test func expansionRegionStaysInBounds() {
        let cell = CGRect(x: 40, y: 60, width: 400, height: 300)
        let region = DeckLayout.expansionRegion(cell: cell, bounds: screen)
        #expect(contained(region, in: screen))
        #expect(region.width == 640)
    }
}

@Suite("ExposeLayout")
struct ExposeLayoutTests {
    func items(_ sizes: [CGSize]) -> [LayoutItem] {
        sizes.enumerated().map { LayoutItem(id: CGWindowID($0.offset + 1), size: $0.element) }
    }

    @Test func singleWindowNeverUpscales() {
        let result = ExposeLayout.compute(ExposeLayoutInput(items: items([CGSize(width: 400, height: 300)]), bounds: screen, titleBandHeight: 40))
        #expect(result.scale == 1)
        let frame = result.frames[1]!
        #expect(frame.width == 400 && frame.height == 340)
        #expect(contained(frame, in: screen))
    }

    @Test(arguments: [2, 5, 9, 16, 30])
    func mixedAspectRatiosFitWithoutOverlap(_ count: Int) {
        let sizes = (0..<count).map { i in
            [CGSize(width: 1440, height: 900), CGSize(width: 600, height: 1200), CGSize(width: 2400, height: 400), CGSize(width: 800, height: 800)][i % 4]
        }
        let result = ExposeLayout.compute(ExposeLayoutInput(items: items(sizes), bounds: screen, titleBandHeight: 44))
        #expect(result.frames.count == count)
        #expect(result.scale <= 1)
        #expect(!overlaps(Array(result.frames.values)))
        for frame in result.frames.values {
            #expect(contained(frame, in: screen))
        }
    }

    @Test func keepsAspectRatio() {
        let result = ExposeLayout.compute(ExposeLayoutInput(items: items([CGSize(width: 3000, height: 1000), CGSize(width: 1000, height: 2000)]), bounds: screen, titleBandHeight: 40))
        let a = result.frames[1]!
        let b = result.frames[2]!
        #expect(abs(a.width / (a.height - 40) - 3) < 0.05)
        #expect(abs(b.width / (b.height - 40) - 0.5) < 0.05)
    }

    @Test func isDeterministic() {
        let input = ExposeLayoutInput(items: items((0..<7).map { CGSize(width: 800 + $0 * 50, height: 600) }), bounds: screen, titleBandHeight: 40)
        #expect(ExposeLayout.compute(input).frames == ExposeLayout.compute(input).frames)
    }

    @Test func maxRowsIsRespected() {
        let input = ExposeLayoutInput(items: items(Array(repeating: CGSize(width: 800, height: 600), count: 6)), bounds: CGRect(x: 0, y: 0, width: 1600, height: 160), titleBandHeight: 30, maxRows: 1)
        let result = ExposeLayout.compute(input)
        #expect(result.rows == 1)
        #expect(Set(result.frames.values.map(\.minY)).count == 1)
    }

    @Test func emptyInput() {
        #expect(ExposeLayout.compute(ExposeLayoutInput(items: [], bounds: screen, titleBandHeight: 40)).frames.isEmpty)
    }
}

@Suite("TitleListLayout")
struct TitleListLayoutTests {
    @Test func groupsDoNotOverlapAndRowsBelongToGroups() {
        var id: CGWindowID = 0
        let groups = (0..<8).map { i -> TitleListGroup in
            TitleListGroup(appID: pid_t(i), windowIDs: (0..<(i % 4 + 1)).map { _ in id += 1; return id })
        }
        let result = TitleListLayout.compute(TitleListLayoutInput(groups: groups, bounds: screen, rowHeight: 40))
        #expect(result.groups.count == 8)
        #expect(!overlaps(result.groups.map(\.frame)))
        for group in result.groups {
            for row in group.rows.values {
                #expect(group.frame.contains(row))
            }
        }
    }

    @Test func tooManyRowsScroll() {
        let groups = [TitleListGroup(appID: 1, windowIDs: Array(1...200))]
        let result = TitleListLayout.compute(TitleListLayoutInput(groups: groups, bounds: screen, rowHeight: 40))
        #expect(result.needsScrolling)
        #expect(result.contentSize.height > screen.height)
    }
}

@Suite("SpatialNavigation")
struct NavigationTests {
    let targets: [(id: Int, rect: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 100, height: 100)),
        (2, CGRect(x: 200, y: 0, width: 100, height: 100)),
        (3, CGRect(x: 0, y: 200, width: 100, height: 100)),
        (4, CGRect(x: 200, y: 200, width: 100, height: 100)),
    ]

    @Test func movesInDirection() {
        #expect(SpatialNavigation.next(from: 1, direction: .right, targets: targets) == 2)
        #expect(SpatialNavigation.next(from: 1, direction: .down, targets: targets) == 3)
        #expect(SpatialNavigation.next(from: 4, direction: .up, targets: targets) == 2)
        #expect(SpatialNavigation.next(from: 4, direction: .left, targets: targets) == 3)
    }

    @Test func staysAtEdgeAndStartsAtFirst() {
        #expect(SpatialNavigation.next(from: 1, direction: .left, targets: targets) == 1)
        #expect(SpatialNavigation.next(from: nil, direction: .left, targets: targets) == 1)
    }
}
