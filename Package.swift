// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WindowDeck", targets: ["WindowDeck"]),
    ],
    dependencies: [
        .package(path: "Packages/WindowDeckCore"),
    ],
    targets: [
        .executableTarget(
            name: "WindowDeck",
            dependencies: [
                .product(name: "WindowDeckCore", package: "WindowDeckCore"),
            ],
            path: "Sources/WindowDeck",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
