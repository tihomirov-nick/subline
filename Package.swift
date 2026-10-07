// swift-tools-version:5.10
import PackageDescription
import Foundation

// Absolute path to the package root: the prebuilt whisper.cpp static library lives in Vendor/.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Subtits",
    platforms: [.macOS("13.3")],
    products: [
        .executable(name: "Subtits", targets: ["Subtits"]),
        .executable(name: "subtits-cli", targets: ["SubtitsCLI"]),
    ],
    targets: [
        // whisper.cpp (built by scripts/build_whisper.sh as a universal static library)
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            linkerSettings: [
                .unsafeFlags(["-L\(packageRoot)/Vendor/whisper/lib"]),
                .linkedLibrary("whisper_all"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Transcription, subtitle layout/rendering, ffmpeg pipeline (no UI)
        .target(
            name: "SubtitsCore",
            dependencies: ["CWhisper"],
            path: "Sources/SubtitsCore"
        ),
        // SwiftUI application
        .executableTarget(
            name: "Subtits",
            dependencies: ["SubtitsCore"],
            path: "Sources/Subtits"
        ),
        // Command line tool for testing the pipeline without UI
        .executableTarget(
            name: "SubtitsCLI",
            dependencies: ["SubtitsCore"],
            path: "Sources/SubtitsCLI"
        ),
    ]
)
