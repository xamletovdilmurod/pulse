// swift-tools-version: 6.0
import PackageDescription

// PulseKit holds everything that is not the app shell.
//
// The split exists so the money logic and the language parser can be tested on macOS in under a second,
// with no simulator in the loop. That matters: the parser needs a large phrase corpus exercised on every
// change, and waiting on a simulator boot for that would kill the iteration speed we need.
let package = Package(
    name: "PulseKit",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "PulseCore", targets: ["PulseCore"]),
        .library(name: "PulseParse", targets: ["PulseParse"]),
        .library(name: "PulseUI", targets: ["PulseUI"]),
        .library(name: "PulseAI", targets: ["PulseAI"]),
    ],
    targets: [
        // Domain: money arithmetic, transactions, categories, budgets. No UI, no I/O, no ML.
        .target(
            name: "PulseCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Deterministic uz/ru/en utterance -> structured expense. Pure Swift, no model required.
        .target(
            name: "PulseParse",
            dependencies: ["PulseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Design system, animations, haptics, and the screens.
        .target(
            name: "PulseUI",
            dependencies: ["PulseCore", "PulseParse"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // On-device inference. Wraps the model behind a protocol so the app builds and runs without it.
        .target(
            name: "PulseAI",
            dependencies: ["PulseCore", "PulseParse"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "PulseCoreTests",
            dependencies: ["PulseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PulseParseTests",
            dependencies: ["PulseParse", "PulseCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
