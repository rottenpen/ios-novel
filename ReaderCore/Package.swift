// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReaderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        // 真实书源联网自检工具（不参与 App 构建）
        .executable(name: "LiveCheck", targets: ["LiveCheck"])
    ],
    dependencies: [
        .package(path: "../Vendor/SwiftSoup")
    ],
    targets: [
        .target(
            name: "ReaderCore",
            dependencies: ["SwiftSoup"],
            path: "Sources/ReaderCore"
        ),
        .executableTarget(
            name: "LiveCheck",
            dependencies: ["ReaderCore"],
            path: "Sources/LiveCheck"
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"],
            path: "Tests/ReaderCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
