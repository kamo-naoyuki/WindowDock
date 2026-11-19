// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WindowDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowDock", targets: ["WindowDock"])],
    targets: [
        .target(name: "WindowDockCore"),
        .executableTarget(name: "WindowDock", dependencies: ["WindowDockCore"]),
        .testTarget(name: "WindowDockCoreTests", dependencies: ["WindowDockCore"])
    ]
)
