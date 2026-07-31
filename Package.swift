// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "whistleYoo",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "whistleYooCore", targets: ["whistleYooCore"]),
        .executable(name: "whistleYoo", targets: ["whistleYooApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(
            name: "whistleYooCore",
            exclude: ["Resources/Localizable.xcstrings"],
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj")
            ]
        ),
        .executableTarget(
            name: "whistleYooApp",
            dependencies: [
                "whistleYooCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            exclude: [
                "Resources/AppIcon.icon",
                "Resources/Info.plist",
                "Resources/whistleYoo.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/en.lproj/InfoPlist.strings"),
                .process("Resources/zh-Hans.lproj/InfoPlist.strings")
            ]
        ),
        .testTarget(name: "whistleYooCoreTests", dependencies: ["whistleYooCore"]),
        .testTarget(name: "whistleYooAppTests", dependencies: ["whistleYooApp"]),
        .testTarget(name: "whistleYooIntegrationTests", dependencies: ["whistleYooCore"])
    ],
    swiftLanguageVersions: [.v5]
)
