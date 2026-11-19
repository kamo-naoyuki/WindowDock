// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WindowDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowDock", targets: ["WindowDock"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")],
    targets: [
        .target(name: "WindowDockCore"),
        .executableTarget(name: "WindowDock", dependencies: ["WindowDockCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "WindowDockCoreTests", dependencies: ["WindowDockCore"])
    ]
)
