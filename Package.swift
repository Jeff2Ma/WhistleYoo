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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
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
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: [
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
        .testTarget(name: "whistleYooIntegrationTests", dependencies: ["whistleYooCore"])
    ],
    swiftLanguageVersions: [.v5]
)
