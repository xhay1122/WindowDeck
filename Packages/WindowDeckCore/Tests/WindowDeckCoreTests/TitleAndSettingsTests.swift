import Foundation
import Testing
@testable import WindowDeckCore

@Suite("TitleFormatter")
struct TitleFormatterTests {
    @Test(arguments: [
        ("README.md — WindowDeck — Visual Studio Code", "Visual Studio Code", "README.md — WindowDeck"),
        ("GitHub - Google Chrome", "Google Chrome", "GitHub"),
        ("Inbox | Mail", "mail", "Inbox"),
        ("Google Chrome", "Google Chrome", "Google Chrome"),
        ("Notes", "Safari", "Notes"),
        ("- Safari", "Safari", "- Safari"),
    ])
    func stripsAppSuffix(_ title: String, _ app: String, _ expected: String) {
        #expect(TitleFormatter.stripAppSuffix(title, appName: app) == expected)
    }

    @Test func emptyTitlesBecomeNumberedPlaceholders() {
        let result = TitleFormatter.format(titles: ["", "Doc", "  "], appName: "Pages", cleanup: TitleCleanup())
        #expect(result[0] == FormattedTitle(core: "Pages · 窗口 1", isPlaceholder: true))
        #expect(result[1].full == "Doc")
        #expect(result[2] == FormattedTitle(core: "Pages · 窗口 2", isPlaceholder: true))
    }

    @Test func foldsCommonPrefixAtSeparator() {
        let result = TitleFormatter.format(
            titles: ["WindowDeck — main.swift", "WindowDeck — Package.swift"],
            appName: "Xcode",
            cleanup: TitleCleanup()
        )
        #expect(result[0] == FormattedTitle(prefix: "WindowDeck — ", core: "main.swift"))
        #expect(result[1] == FormattedTitle(prefix: "WindowDeck — ", core: "Package.swift"))
    }

    @Test func foldsCommonSuffix() {
        let result = TitleFormatter.format(
            titles: ["Issue 12 - project/repo", "Pull request 7 - project/repo"],
            appName: "Safari",
            cleanup: TitleCleanup()
        )
        #expect(result[0].core == "Issue 12")
        #expect(result[0].suffix == " - project/repo")
        #expect(result[1].core == "Pull request 7")
    }

    @Test func doesNotSplitWords() {
        let result = TitleFormatter.format(titles: ["Report2024", "Report2025"], appName: "Numbers", cleanup: TitleCleanup())
        #expect(result.map(\.prefix) == ["", ""])
    }

    @Test func identicalTitlesStayIntact() {
        let result = TitleFormatter.format(titles: ["Untitled — Draft", "Untitled — Draft"], appName: "TextEdit", cleanup: TitleCleanup())
        #expect(result.allSatisfy { !$0.core.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(result.allSatisfy { $0.full == "Untitled — Draft" })
    }

    @Test func cleanupCanBeDisabled() {
        var cleanup = TitleCleanup()
        cleanup.stripAppSuffix = false
        cleanup.foldCommonAffix = false
        let result = TitleFormatter.format(titles: ["A — X — Code", "B — X — Code"], appName: "Code", cleanup: cleanup)
        #expect(result[0] == FormattedTitle(core: "A — X — Code"))
    }

    @Test func normalizesNewlines() {
        #expect(TitleFormatter.normalize(" a\nb\r\nc ") == "a b c")
    }

    @Test(arguments: [
        (Truncation.tail, "abcd…"),
        (Truncation.head, "…ghij"),
        (Truncation.middle, "ab…ij"),
    ])
    func truncation(_ mode: Truncation, _ expected: String) {
        #expect(TitleFormatter.truncate("abcdefghij", keeping: 4, mode: mode) == expected)
    }

    @Test func truncationKeepsShortText() {
        #expect(TitleFormatter.truncate("短标题", keeping: 10, mode: .middle) == "短标题")
        #expect(TitleFormatter.truncate("😀😀😀😀", keeping: 2, mode: .middle) == "😀…😀")
    }
}

@Suite("AppSettings")
struct AppSettingsTests {
    @Test func roundTrip() throws {
        var settings = AppSettings()
        settings.titleStyle.fontSize = 28
        settings.hotkeys.deck = KeyCombo(keyCode: 2, carbonModifiers: 256)
        settings.excludedBundleIDs = ["com.example.app"]
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(decoded == settings)
    }

    @Test func defaultsHaveNoHotkeys() {
        let settings = AppSettings()
        #expect(settings.hotkeys.deck == nil)
        #expect(settings.hotkeys.expose == nil)
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let json = #"{"showThumbnails": false, "titleStyle": {"fontSize": 22}, "deck": {}}"#
        let settings = try SettingsCodec.decode(Data(json.utf8))
        #expect(settings.showThumbnails == false)
        #expect(settings.titleStyle.fontSize == 22)
        #expect(settings.titleStyle.maxLines == 2)
        #expect(settings.deck == DeckSettings())
        #expect(settings.gesture == GestureSettings())
        #expect(settings.schemaVersion == AppSettings.currentSchemaVersion)
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let json = #"{"titleStyle": {"fontSize": 200, "maxLines": 9}, "gesture": {"fingers": 7, "sensitivity": 3}, "deck": {"contentPeek": -5}}"#
        let settings = try SettingsCodec.decode(Data(json.utf8))
        #expect(settings.titleStyle.fontSize == 40)
        #expect(settings.titleStyle.maxLines == 3)
        #expect(settings.gesture.fingers == 3)
        #expect(settings.gesture.sensitivity == 1)
        #expect(settings.deck.contentPeek == 0)
    }

    @Test func wrongTypesFallBackToDefaults() throws {
        let json = #"{"showThumbnails": "yes", "multiDisplay": "unknown"}"#
        let settings = try SettingsCodec.decode(Data(json.utf8))
        #expect(settings.showThumbnails == true)
        #expect(settings.multiDisplay == .perScreen)
    }

    @Test func themeDefaultsToSystemAndRoundTrips() throws {
        // 旧版本配置没有 theme 字段，或值无法识别时，回退到跟随系统。
        let old = try SettingsCodec.decode(Data(#"{"appearance": {"dimOpacity": 0.5}}"#.utf8))
        #expect(old.appearance.theme == .system)
        #expect(old.appearance.dimOpacity == 0.5)
        let unknown = try SettingsCodec.decode(Data(#"{"appearance": {"theme": "sepia"}}"#.utf8))
        #expect(unknown.appearance.theme == .system)

        var settings = AppSettings()
        settings.appearance.theme = .dark
        #expect(try SettingsCodec.decode(SettingsCodec.encode(settings)).appearance.theme == .dark)
    }

    @Test func overlayThemeDefaultsToFollowAppAndRoundTrips() throws {
        // 旧版本配置没有 overlayTheme 字段，或值无法识别时，回退到跟随应用。
        let old = try SettingsCodec.decode(Data(#"{"appearance": {"theme": "light"}}"#.utf8))
        #expect(old.appearance.overlayTheme == .followApp)
        let unknown = try SettingsCodec.decode(Data(#"{"appearance": {"overlayTheme": "sepia"}}"#.utf8))
        #expect(unknown.appearance.overlayTheme == .followApp)

        var settings = AppSettings()
        settings.appearance.theme = .light
        settings.appearance.overlayTheme = .dark
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(decoded.appearance.theme == .light)
        #expect(decoded.appearance.overlayTheme == .dark)
    }

    @Test func sensitivityMapsToThreshold() {
        var g = GestureSettings()
        g.sensitivity = 0
        #expect(abs(g.distanceThreshold - 0.18) < 1e-9)
        g.sensitivity = 1
        #expect(abs(g.distanceThreshold - 0.06) < 1e-9)
    }

    @Test func estimatedBandHeightGrowsWithFont() {
        var style = TitleStyle()
        let base = style.estimatedBandHeight()
        style.fontSize = 32
        #expect(style.estimatedBandHeight() > base)
    }
}

@Suite("MRUOrdering")
struct MRUOrderingTests {
    @Test func timestampsFirstThenFallback() {
        let now = Date()
        let items: [(String, Date?, Int)] = [
            ("old", now.addingTimeInterval(-10), 0),
            ("none-back", nil, 5),
            ("new", now, 9),
            ("none-front", nil, 1),
        ]
        let sorted = MRUOrdering.sort(items, timestamp: { $0.1 }, fallbackRank: { $0.2 }).map(\.0)
        #expect(sorted == ["new", "old", "none-front", "none-back"])
    }
}
