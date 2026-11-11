// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CodexWatchPet",
    platforms: [
        .iOS(.v26),
        .watchOS(.v11),
        .macOS(.v26)
    ],
    products: [
        .library(name: "WristArenaFeature", targets: ["WristArenaFeature"]),
        .library(name: "CodexMobilityCore", targets: ["CodexMobilityCore"]),
        .library(name: "CodexMobilityPhoneFeature", targets: ["CodexMobilityPhoneFeature"]),
        .library(name: "CodexMobilityMacFeature", targets: ["CodexMobilityMacFeature"]),
        .library(name: "CodexWatchCore", targets: ["CodexWatchCore"]),
        .library(name: "CodexWatchBridgeCore", targets: ["CodexWatchBridgeCore"]),
        .library(name: "CodexWatchSharedUI", targets: ["CodexWatchSharedUI"]),
        .library(name: "CodexWatchPhoneFeature", targets: ["CodexWatchPhoneFeature"]),
        .library(name: "CodexWatchWatchFeature", targets: ["CodexWatchWatchFeature"]),
        .library(name: "CodexWatchIntents", targets: ["CodexWatchIntents"]),
        .library(name: "CodexWatchWidgets", targets: ["CodexWatchWidgets"]),
        .executable(name: "CodexWatchBridge", targets: ["CodexWatchBridge"]),
        .executable(name: "CodexWatchNotifyRelay", targets: ["CodexWatchNotifyRelay"])
    ],
    targets: [
        .target(name: "WristArenaCore", resources: [.process("Resources")]),
        .target(name: "WristArenaFeature", dependencies: ["WristArenaCore"], exclude: ["Resources/app.js", "Resources/core.js", "Resources/builds.js", "Resources/effects.js", "Resources/audio.js", "Resources/index.html", "Resources/style.css"], resources: [.copy("Resources/Web")]),
        .testTarget(name: "WristArenaCoreTests", dependencies: ["WristArenaCore"]),
        .target(name: "CodexMobilityCore"),
        .target(
            name: "CodexMobilityPhoneFeature",
            dependencies: ["CodexMobilityCore"]
        ),
        .target(
            name: "CodexMobilityMacFeature",
            dependencies: ["CodexMobilityCore", "CodexWatchCore", "WristArenaFeature"]
        ),
        .target(name: "CodexWatchCore"),
        .target(
            name: "CodexWatchBridgeCore",
            dependencies: ["CodexWatchCore"]
        ),
        .executableTarget(
            name: "CodexWatchBridge",
            dependencies: ["CodexWatchBridgeCore"]
        ),
        .executableTarget(
            name: "CodexWatchNotifyRelay",
            dependencies: ["CodexWatchBridgeCore"]
        ),
        .target(
            name: "CodexWatchSharedUI",
            dependencies: ["CodexWatchCore"]
        ),
        .target(
            name: "CodexWatchPhoneFeature",
            dependencies: ["CodexWatchCore", "CodexWatchSharedUI", "CodexMobilityPhoneFeature"]
        ),
        .target(
            name: "CodexWatchWatchFeature",
            dependencies: ["CodexWatchCore", "CodexWatchSharedUI", "WristArenaFeature"]
        ),
        .target(
            name: "CodexWatchIntents",
            dependencies: ["CodexWatchCore"]
        ),
        .target(
            name: "CodexWatchWidgets",
            dependencies: ["CodexWatchCore", "CodexWatchSharedUI"]
        ),
        .testTarget(
            name: "CodexMobilityCoreTests",
            dependencies: ["CodexMobilityCore"]
        ),
        .testTarget(
            name: "CodexMobilityPhoneFeatureTests",
            dependencies: ["CodexMobilityPhoneFeature"]
        ),
        .testTarget(
            name: "CodexMobilityMacFeatureTests",
            dependencies: ["CodexMobilityMacFeature", "CodexMobilityPhoneFeature"]
        ),
        .testTarget(
            name: "CodexWatchCoreTests",
            dependencies: ["CodexWatchCore"]
        ),
        .testTarget(
            name: "CodexWatchBridgeCoreTests",
            dependencies: ["CodexWatchBridgeCore"]
        ),
        .testTarget(
            name: "CodexWatchPhoneFeatureTests",
            dependencies: ["CodexWatchPhoneFeature"]
        ),
        .testTarget(
            name: "CodexWatchWatchFeatureTests",
            dependencies: ["CodexWatchWatchFeature"]
        )
    ]
)
