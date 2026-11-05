import AppKit
import WindowDeckCore

/// 开发用命令行入口：
///   --self-test               打印能力 / 权限 / 窗口目录统计（只输出应用名与数量，不输出窗口标题）后退出
///   --render-preview <dir>    用合成数据离屏渲染覆盖层到 PNG（深色 + 浅色，浅色文件带 -light 后缀），便于检查布局（不需要任何权限）
@MainActor
enum DevTools {
    static func handle(arguments: [String]) -> Bool {
        if arguments.contains("--self-test") {
            runSelfTest()
            return true
        }
        if let index = arguments.firstIndex(of: "--render-preview") {
            let dir = arguments.indices.contains(index + 1) ? arguments[index + 1] : FileManager.default.currentDirectoryPath
            renderPreviews(to: URL(fileURLWithPath: dir))
            return true
        }
        return false
    }

    // MARK: 自检

    private static var retained: [AnyObject] = []

    private static func runSelfTest() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let caps = CapabilityRegistry.probe()
        print("== capabilities")
        for item in caps.items { print("  \(item.available ? "✓" : "✗") \(item.name)") }
        print("== permissions")
        print("  accessibility=\(PermissionService.isAccessibilityTrusted) screenRecording=\(PermissionService.isScreenRecordingGranted)")
        print("  currentSpaces=\(SkyLight.currentSpaceIDs().count)")
        let conflict = GestureConflictStatus.detect(fingers: 3)
        print("== gesture conflict: verticalSwipe=\(conflict.verticalSwipeValue.map(String.init) ?? "nil") missionControl=\(conflict.missionControlGestureEnabled) appExpose=\(conflict.appExposeGestureEnabled) threeFingerDrag=\(conflict.threeFingerDrag) → hasConflict=\(conflict.hasConflict)")
        if let list = Multitouch.deviceList() {
            print("== touch devices: \(CFArrayGetCount(list))")
        }

        let store = SettingsStore(defaults: UserDefaults(suiteName: "windowdeck.selftest") ?? .standard)
        let catalog = WindowCatalog(settingsStore: store, capabilities: caps)
        retained.append(catalog)
        let started = Date()
        catalog.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                let begin = Date()
                let snapshot = catalog.snapshot()
                let snapshotMs = Date().timeIntervalSince(begin) * 1000
                print("== catalog after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(snapshot.apps.count) apps, \(snapshot.windows.count) windows (snapshot \(String(format: "%.1f", snapshotMs))ms)")
                for app in snapshot.apps where !app.windowIDs.isEmpty {
                    let windows = snapshot.windows(of: app)
                    let minimized = windows.filter(\.isMinimized).count
                    let otherSpace = windows.filter { !$0.isOnCurrentSpace }.count
                    let readOnly = windows.filter { !$0.capabilities.contains(.focus) }.count
                    print("  \(app.name): \(windows.count) windows (minimized \(minimized), other space \(otherSpace), read-only \(readOnly))\(app.isHidden ? " [hidden]" : "")")
                }
                if PermissionService.isScreenRecordingGranted, let first = snapshot.apps.first(where: { !$0.windowIDs.isEmpty }),
                   let window = snapshot.windows(of: first).first(where: { !$0.isMinimized }) {
                    let thumbs = ThumbnailService()
                    retained.append(thumbs)
                    thumbs.isEnabled = true
                    let t0 = Date()
                    thumbs.onUpdate = { _, image in
                        print("== thumbnail captured: \(image.width)x\(image.height) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms")
                        exit(0)
                    }
                    thumbs.refresh([window])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        print("== thumbnail capture timed out")
                        exit(0)
                    }
                } else {
                    exit(0)
                }
            }
        }
        NSApplication.shared.run()
    }

    // MARK: 离屏预览

    private static func renderPreviews(to dir: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let screen = NSScreen.main else {
            print("no screen")
            return
        }
        let (snapshot, images) = syntheticSnapshot(screen: screen)
        let thumbnails = ThumbnailService()
        for (id, image) in images { thumbnails.inject(image, for: id) }

        var settings = AppSettings()
        var dark = true
        func render(_ name: String, mode: OverlayMode, tweak: (inout AppSettings) -> Void = { _ in }) {
            var s = settings
            tweak(&s)
            let context = OverlayContext(
                mode: mode,
                snapshot: snapshot,
                settings: s,
                windowIDs: Set(snapshot.windows.keys),
                exposePID: snapshot.apps.first?.pid,
                includeAppsWithoutWindows: true
            )
            let content = OverlayContentView(screen: screen, context: context, thumbnails: thumbnails)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = content
            content.present()
            // 等出现动画结束再截图。
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            let file = name + (dark ? "" : "-light") + ".png"
            write(view: content, dark: dark, to: dir.appendingPathComponent(file))
            print("rendered \(file)")
        }
        for isDark in [true, false] {
            dark = isDark
            settings = AppSettings()
            render("deck", mode: .deck)
            render("deck-large-title", mode: .deck) { $0.titleStyle.fontSize = 26; $0.titleStyle.maxLines = 2; $0.trafficLights.visibility = .always }
            render("expose", mode: .expose) { $0.trafficLights.visibility = .always }
            render("deck-title-only", mode: .deck) { $0.showThumbnails = false; $0.titleStyle.fontSize = 18 }
            render("expose-title-only", mode: .expose) { $0.showThumbnails = false; $0.titleStyle.fontSize = 22 }
            settings.titleStyle.background = .bar
            render("deck-bar", mode: .deck)
        }
    }

    private static func write(view: NSView, dark: Bool, to url: URL) {
        let scale: CGFloat = 1
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        // 离屏时没有桌面可模糊：用纯色背景代替（深色 / 浅色各一种）。
        let backdrop = dark ? NSColor(srgbRed: 0.18, green: 0.22, blue: 0.3, alpha: 1) : NSColor(srgbRed: 0.82, green: 0.86, blue: 0.92, alpha: 1)
        context.setFillColor(backdrop.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        CATransaction.flush()
        view.layer?.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func syntheticSnapshot(screen: NSScreen) -> (CatalogSnapshot, [CGWindowID: CGImage]) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let specs: [(String, [String])] = [
            ("Xcode", ["WindowDeck — OverlayContentView.swift", "WindowDeck — CardView.swift", "WindowDeck — Package.swift", "Notes — README.md", "WindowDeck — DeckLayout.swift", "WindowDeck — TitleFormatter.swift", "WindowDeck — AppDelegate.swift"]),
            ("Safari", ["GitHub - Pull request #42 - project/repo", "Issue 17: 窗口标题太长时如何截断 - project/repo"]),
            ("Terminal", ["~/dodoFE/personal/WindowDeck — zsh — 120×40"]),
            ("飞书", ["产品周会纪要（2026-11-05）", "设计评审：WindowDeck 交互稿", ""]),
            ("Finder", ["下载", "文稿"]),
            ("预览", ["technical-design.pdf"]),
        ]
        var windows: [CGWindowID: WindowInfo] = [:]
        var apps: [AppInfo] = []
        var images: [CGWindowID: CGImage] = [:]
        var next: CGWindowID = 100
        let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemTeal, .systemPink]
        for (index, spec) in specs.enumerated() {
            var ids: [CGWindowID] = []
            for (w, title) in spec.1.enumerated() {
                let id = next
                next += 1
                let size = [CGSize(width: 1440, height: 900), CGSize(width: 1100, height: 800), CGSize(width: 900, height: 1000)][(index + w) % 3]
                var info = WindowInfo(id: id, pid: pid, title: title, frame: CGRect(x: 80 + CGFloat(w) * 40, y: 80 + CGFloat(w) * 30, width: size.width, height: size.height))
                if index == 0, w == 3 { info.isMinimized = true }
                if index == 1, w == 1 { info.isOnCurrentSpace = false }
                windows[id] = info
                ids.append(id)
                images[id] = fakeWindowImage(size: size, color: palette[index % palette.count], title: title)
            }
            apps.append(AppInfo(pid: pid, bundleID: nil, name: spec.0, windowIDs: ids))
        }
        // 同一个 pid 的多个"应用"只用于预览：AppInfo 的 id 需要唯一，这里用负数区分。
        apps = apps.enumerated().map { index, app in
            AppInfo(pid: index == 0 ? app.pid : -Int32(index), bundleID: nil, name: app.name, isHidden: index == 4, windowIDs: app.windowIDs)
        }
        for app in apps {
            for id in app.windowIDs {
                if let w = windows[id] {
                    windows[id] = WindowInfo(id: w.id, pid: app.pid, title: w.title, frame: w.frame, isMinimized: w.isMinimized, isFullscreen: w.isFullscreen, isOnCurrentSpace: w.isOnCurrentSpace, capabilities: w.capabilities)
                }
            }
        }
        return (CatalogSnapshot(apps: apps, windows: windows, frontmostPID: apps.first?.pid), images)
    }

    private static func fakeWindowImage(size: CGSize, color: NSColor, title: String) -> CGImage? {
        let w = Int(size.width / 2)
        let h = Int(size.height / 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: 0, y: h - 26, width: w, height: 26))
        ctx.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor)
        for i in 0..<12 {
            ctx.fill(CGRect(x: 20, y: h - 50 - i * 22, width: Int.random(in: 80...(w - 40)), height: 10))
        }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 70, y: h - 20))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
