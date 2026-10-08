// swift-tools-version:5.10
import PackageDescription
import Foundation

// Absolute path to the package root: the prebuilt whisper.cpp static library lives in Vendor/.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Subline",
    platforms: [.macOS("13.3")],
    products: [
        .executable(name: "Subline", targets: ["Subline"]),
        .executable(name: "subline-cli", targets: ["SublineCLI"]),
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
            name: "SublineCore",
            dependencies: ["CWhisper"],
            path: "Sources/SublineCore"
        ),
        // SwiftUI application
        .executableTarget(
            name: "Subline",
            dependencies: ["SublineCore"],
            path: "Sources/Subline"
        ),
        // Command line tool for testing the pipeline without UI
        .executableTarget(
            name: "SublineCLI",
            dependencies: ["SublineCore"],
            path: "Sources/SublineCLI"
        ),
    ]
)
