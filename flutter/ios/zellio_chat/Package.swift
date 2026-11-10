// swift-tools-version: 5.9
// Swift Package Manager manifest for the zellio_chat Flutter plugin.
//
// The native iOS SDK sources are NOT in git here. `scripts/vendor-ios.sh` copies them from sdks/ios/Sources
// into Sources/zellio_chat/Vendor (and removes the cross-module import), so the plugin is ONE module and needs
// no new pod on CocoaPods trunk. Run the script before building on iOS and before publishing.

import PackageDescription

let package = Package(
    name: "zellio_chat",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "zellio-chat", targets: ["zellio_chat"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "zellio_chat",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("Vendor/PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
