// swift-tools-version:5.9
// The public repo (github.com/zellio-ai/zellio-chat-sdk) is this sdks/ folder, so Swift Package Manager reads
// this file at the repo root. It is the same package as ios/Package.swift, with paths into ios/.
// Keep the two files in step.
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
        .target(name: "ZellioChatCore", path: "ios/Sources/ZellioChatCore"),
        .target(
            name: "ZellioChat",
            dependencies: ["ZellioChatCore"],
            path: "ios/Sources/ZellioChat",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ZellioChatCoreTests",
            dependencies: ["ZellioChatCore"],
            path: "ios/Tests/ZellioChatCoreTests"
        ),
    ]
)
