import AppKit

MainActor.assumeIsolated {
    if DevTools.handle(arguments: CommandLine.arguments) {
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
