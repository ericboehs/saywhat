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
    targets: [
        // Pure, hardware-free core logic and shared value types. Engines
        // (capture, transcription, diarization, summarization) land here behind
        // protocols per DESIGN.md §14; this is the unit-testable heart.
        .target(
            name: "SayWhatCore",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SayWhatCoreTests",
            dependencies: ["SayWhatCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
