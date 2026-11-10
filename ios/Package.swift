// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZellioChat",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ZellioChat", targets: ["ZellioChat"]),
        .library(name: "ZellioChatCore", targets: ["ZellioChatCore"]),
    ],
    dependencies: [],
    targets: [
        // Foundation only. Holds all logic. Builds and tests on Linux.
        .target(name: "ZellioChatCore"),
        // SwiftUI and UIKit. Every source file is wrapped in #if canImport(SwiftUI) && canImport(UIKit),
        // so the package still resolves and builds (as an empty module) on Linux.
        .target(
            name: "ZellioChat",
            dependencies: ["ZellioChatCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ZellioChatCoreTests",
            dependencies: ["ZellioChatCore"]
        ),
    ]
)
