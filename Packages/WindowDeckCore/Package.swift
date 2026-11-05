// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowDeckCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WindowDeckCore", targets: ["WindowDeckCore"]),
    ],
    targets: [
        .target(name: "WindowDeckCore"),
        .testTarget(name: "WindowDeckCoreTests", dependencies: ["WindowDeckCore"]),
    ]
)
