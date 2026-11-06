import CoreGraphics
import Foundation
import Testing
@testable import WindowDeckCore

@Suite("BrowserTabs")
struct BrowserTabsTests {
    private func browserWindow(_ id: Int, title: String, bounds: CGRect?) -> BrowserWindowTabs {
        BrowserWindowTabs(id: .integer(id), title: title, bounds: bounds, activeTabIndex: 0, tabs: [BrowserTab(id: .integer(id * 10), title: title, url: "https://example.com")])
    }

    @Test func matchesByFrameWithinTolerance() {
        let windows = [
            WindowInfo(id: 1, pid: 9, title: "A", frame: CGRect(x: 0, y: 25, width: 1200, height: 800)),
            WindowInfo(id: 2, pid: 9, title: "B", frame: CGRect(x: 300, y: 100, width: 900, height: 700)),
        ]
        let result = BrowserTabMatcher.match([
            browserWindow(100, title: "B", bounds: CGRect(x: 301, y: 100, width: 900, height: 699)),
            browserWindow(200, title: "A", bounds: CGRect(x: 0, y: 25, width: 1200, height: 800)),
        ], to: windows)
        #expect(result.map(\.windowID) == [2, 1])
    }

    @Test func overlappingFramesAreDisambiguatedByTitle() {
        let frame = CGRect(x: 0, y: 25, width: 1200, height: 800)
        let windows = [
            WindowInfo(id: 1, pid: 9, title: "Docs", frame: frame),
            WindowInfo(id: 2, pid: 9, title: "Mail", frame: frame),
        ]
        let result = BrowserTabMatcher.match([
            browserWindow(100, title: "Mail", bounds: frame),
            browserWindow(200, title: "Docs", bounds: frame),
        ], to: windows)
        #expect(result.map(\.windowID) == [2, 1])
    }

    @Test func fallsBackToUniqueTitleAndLeavesAmbiguousUnmatched() {
        let windows = [
            WindowInfo(id: 1, pid: 9, title: "Docs", frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            WindowInfo(id: 2, pid: 9, title: "Same", frame: CGRect(x: 600, y: 0, width: 500, height: 500)),
            WindowInfo(id: 3, pid: 9, title: "Same", frame: CGRect(x: 0, y: 600, width: 500, height: 500)),
        ]
        let result = BrowserTabMatcher.match([
            browserWindow(100, title: "Docs", bounds: nil),
            browserWindow(200, title: "Same", bounds: CGRect(x: 2000, y: 2000, width: 10, height: 10)),
        ], to: windows)
        #expect(result[0].windowID == 1)
        #expect(result[1].windowID == nil)
    }

    @Test func eachSystemWindowIsUsedOnce() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let windows = [WindowInfo(id: 1, pid: 9, title: "X", frame: frame)]
        let result = BrowserTabMatcher.match([
            browserWindow(100, title: "X", bounds: frame),
            browserWindow(200, title: "X", bounds: frame),
        ], to: windows)
        #expect(result.compactMap(\.windowID) == [1])
    }

    @Test(arguments: [
        ("https://www.github.com/org/repo", "github.com"),
        ("https://mail.google.com/mail/u/0/", "mail.google.com"),
        ("chrome://settings/", "chrome://settings"),
        ("about:blank", "about:"),
        ("file:///Users/me/a.html", "file:"),
    ])
    func displayHost(_ url: String, _ expected: String) {
        #expect(BrowserTab(id: .integer(1), title: "", url: url).displayHost == expected)
    }

    @Test func activeTabIsBoundsChecked() {
        var window = browserWindow(1, title: "A", bounds: nil)
        #expect(window.activeTab?.id == .integer(10))
        window.activeTabIndex = 5
        #expect(window.activeTab == nil)
    }

    @Test func chromeAXTitleMatchesByPrefix() {
        #expect(BrowserTabMatcher.titleMatches(system: "Inbox - Google Chrome", browser: "Inbox"))
        #expect(BrowserTabMatcher.titleMatches(system: "Inbox - 属于“工作”群组 - Google Chrome - Me", browser: "Inbox"))
        #expect(BrowserTabMatcher.titleMatches(system: "Inbox", browser: "Inbox"))
        #expect(!BrowserTabMatcher.titleMatches(system: "Inbox2 - Google Chrome", browser: "Inbox"))
        #expect(!BrowserTabMatcher.titleMatches(system: "Inbox - Google Chrome", browser: ""))
    }

    @Test func overlappingFramesUseChromeStyleTitles() {
        let frame = CGRect(x: 0, y: 25, width: 1200, height: 800)
        let windows = [
            WindowInfo(id: 1, pid: 9, title: "Docs - Google Chrome", frame: frame),
            WindowInfo(id: 2, pid: 9, title: "Mail - Google Chrome", frame: frame),
        ]
        let result = BrowserTabMatcher.match([
            browserWindow(100, title: "Mail", bounds: frame),
            browserWindow(200, title: "Docs", bounds: nil),
        ], to: windows)
        #expect(result.map(\.windowID) == [2, 1])
    }

    @Test(arguments: [
        ("https://mail.google.com/mail/u/0/", "mail.google.com"),
        ("https://www.github.com/a", "github.com"),
        ("https://github.com/a", "github.com"),
        ("https://www.news.example.com/", "news.example.com"),
        ("https://a.b.example.com/", "b.example.com"),
        ("https://news.bbc.co.uk/x", "bbc.co.uk"),
        ("http://192.168.1.10:8080/", "192.168.1.10"),
        ("http://localhost:3000/", "localhost"),
        ("chrome://settings/", "chrome://"),
        ("file:///tmp/a.html", "file://"),
    ])
    func groupingDomain(_ url: String, _ expected: String) {
        #expect(BrowserTab(id: .integer(1), title: "", url: url).groupingDomain == expected)
    }

    @Test func groupsByDomainAndMergesSingles() {
        func tab(_ n: Int, _ url: String) -> BrowserTab { BrowserTab(id: .integer(n), title: "\(n)", url: url) }
        let windows = [
            BrowserWindowTabs(id: .integer(1), title: "", bounds: nil, activeTabIndex: 0, tabs: [
                tab(1, "https://a.com/1"), tab(2, "https://x.com/"), tab(3, "https://mail.google.com/"),
            ]),
            BrowserWindowTabs(id: .integer(2), title: "", bounds: nil, activeTabIndex: 0, tabs: [
                tab(4, "https://mail.google.com/x"), tab(5, "https://y.com/"), tab(6, "https://a.com/2"), tab(7, "https://translate.google.com/"),
            ]),
        ]
        let groups = BrowserTabGrouper.groupByDomain(windows)
        // a.com、mail.google.com 各 2 个（a.com 先出现排前）；x.com、y.com、translate.google.com 合并为"其他网站"。
        #expect(groups.map(\.domain) == ["a.com", "mail.google.com", nil])
        #expect(groups[1].positions == [BrowserTabPosition(window: 0, tab: 2), BrowserTabPosition(window: 1, tab: 0)])
        #expect(groups[2].positions == [BrowserTabPosition(window: 0, tab: 1), BrowserTabPosition(window: 1, tab: 1), BrowserTabPosition(window: 1, tab: 3)])
    }

    @Test func singleLoneDomainIsNotMergedIntoOther() {
        let windows = [BrowserWindowTabs(id: .integer(1), title: "", bounds: nil, activeTabIndex: 0, tabs: [
            BrowserTab(id: .integer(1), title: "", url: "https://a.com/1"),
            BrowserTab(id: .integer(2), title: "", url: "https://a.com/2"),
            BrowserTab(id: .integer(3), title: "", url: "https://b.com/"),
        ])]
        #expect(BrowserTabGrouper.groupByDomain(windows).map(\.domain) == ["a.com", "b.com"])
    }

    @Test func exposeSettingsDefaultsWhenFieldsMissing() throws {
        let data = Data(#"{"showMinimizedStrip": false}"#.utf8)
        let settings = try JSONDecoder().decode(ExposeSettings.self, from: data)
        #expect(settings.showMinimizedStrip == false)
        #expect(settings.showBrowserTabs == true)
        #expect(settings.includeIncognitoTabs == false)
        #expect(settings.tabGrouping == .domain)
    }
}
