// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode turns on complete data-race checking by default
// (QUALITY.md §1). CI additionally builds with `-warnings-as-errors`; local
// builds may relax that while iterating.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "SayWhat",
    platforms: [
        // macOS 26 (Tahoe) only — the design depends on SpeechAnalyzer and
        // Foundation Models, which ship in macOS 26. See QUALITY.md §1.
        .macOS("26.0"),
    ],
    products: [
        .library(name: "SayWhatCore", targets: ["SayWhatCore"]),
    ],
    dependencies: [
        // Live + final diarization (Sortformer / pyannote) and batch Parakeet
        // ASR. Apache-2.0; the Sortformer model is NVIDIA Open Model License —
        // note for commercial use (CLAUDE.md). Models download on first use.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.15.4")
        ),
    ],
    targets: [
        // Pure, hardware-free core logic and shared value types. Engines
        // (capture, transcription, diarization, summarization) land here behind
        // protocols per DESIGN.md §14; this is the unit-testable heart.
        .target(
            name: "SayWhatCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SayWhatCoreTests",
            dependencies: ["SayWhatCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
