// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Carla",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CarlaAudio", targets: ["CarlaAudio"]),
        .library(name: "CarlaTranscription", targets: ["CarlaTranscription"]),
        .library(name: "CarlaStorage", targets: ["CarlaStorage"]),
        .library(name: "CarlaRecording", targets: ["CarlaRecording"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/ggerganov/whisper.spm.git", branch: "master")
    ],
    targets: [
        .target(
            name: "CarlaCoreTypes",
            dependencies: [],
            path: "Sources/CoreTypes"
        ),
        .target(
            name: "CarlaAudio",
            dependencies: [
                "CarlaCoreTypes"
            ],
            path: "Sources/Audio"
        ),
        .target(
            name: "CarlaTranscription",
            dependencies: [
                .product(name: "whisper", package: "whisper.spm")
            ],
            path: "Sources/Transcription"
        ),
        .target(
            name: "CarlaModels",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Models"
        ),
        .target(
            name: "CarlaStorage",
            dependencies: [
                "CarlaModels",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Storage"
        ),
        .target(
            name: "CarlaRecording",
            dependencies: [
                "CarlaAudio",
                "CarlaCoreTypes",
                "CarlaModels",
                "CarlaStorage",
                "CarlaTranscription"
            ],
            path: "Sources/App",
            exclude: [
                "AppState.swift",
                "PermissionManager.swift",
                "CarlaApp.swift",
                "MenuBarMenuView.swift"
            ],
            sources: [
                "RecordingCoordinator.swift"
            ]
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: ["CarlaTranscription"],
            path: "Tests/TranscriptionTests"
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["CarlaModels", "CarlaStorage"],
            path: "Tests/StorageTests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "CarlaModels",
                "CarlaTranscription",
                "CarlaStorage"
            ],
            path: "Tests/IntegrationTests"
        ),
        .testTarget(
            name: "AudioTests",
            dependencies: [
                "CarlaAudio"
            ],
            path: "Tests/Audio"
        )
    ]
)
