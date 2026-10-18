// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CamillaCompanion",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "camillacompanion", targets: ["CamillaCompanion"]),
        .executable(name: "camillacompanion-checks", targets: ["AutoAudioChecks"])
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(name: "AutoAudioCore"),
        .target(name: "AutoAudioPlatform", dependencies: ["AutoAudioCore", .product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "CamillaCompanion", dependencies: ["AutoAudioCore", "AutoAudioPlatform"]),
        .executableTarget(name: "AutoAudioChecks", dependencies: ["AutoAudioCore", "AutoAudioPlatform"], path: "Checks"),
        .testTarget(name: "AutoAudioCoreTests", dependencies: ["AutoAudioCore", "AutoAudioPlatform"])
    ]
)
