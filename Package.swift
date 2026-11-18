// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Debrief",
    platforms: [.macOS(.v15)],
    targets: [
        // Capture → crash-safe track file → mixdown. No UI, testable on its own.
        .target(name: "RecorderCore"),
        // SwiftUI app + menu bar item. Must run from the .app bundle (see build-app.sh).
        .executableTarget(name: "Debrief", dependencies: ["RecorderCore"]),
        // Headless check of the writer / crash-recovery / mixdown path (no permissions needed).
        .executableTarget(name: "RecorderSelfTest", dependencies: ["RecorderCore"]),
    ],
    swiftLanguageModes: [.v5]
)
