// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "QuotaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaCore"],
            resources: [.copy("Resources/logos"), .copy("Resources/brands"), .copy("Resources/fonts")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
