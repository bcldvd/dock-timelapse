// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DockTimelapse",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "dock-timelapse", targets: ["DockTimelapseCLI"]),
        .executable(name: "DockTimelapseApp", targets: ["DockTimelapseApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DockCore"),
        .target(name: "DockMac", dependencies: ["DockCore"]),
        .target(name: "DockRender", dependencies: ["DockCore"]),
        .executableTarget(name: "DockTimelapseCLI", dependencies: [
            "DockCore", "DockMac", "DockRender",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .target(name: "DockAppModel", dependencies: ["DockCore", "DockMac", "DockRender"]),
        .executableTarget(name: "DockTimelapseApp", dependencies: ["DockAppModel", "DockCore", "DockMac", "DockRender"]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
        .testTarget(name: "DockMacTests", dependencies: ["DockMac"]),
        .testTarget(name: "DockRenderTests", dependencies: ["DockRender"]),
        .testTarget(name: "DockAppModelTests", dependencies: ["DockAppModel"]),
    ]
)
