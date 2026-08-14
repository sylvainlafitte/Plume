// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "plume",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned exactly on purpose — FluidAudio has made source-breaking changes in
        // *patch* releases and ships no CHANGELOG. A bump is a project, not a chore:
        // recompile, then re-run diarization against the test corpus and compare DER.
        // See AGENTS.md.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        // All logic lives here so tests can reach it via `@testable import PlumeKit`.
        .target(
            name: "PlumeKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        // Thin shim that produces the binary inside Plume.app.
        //
        // No `unsafeFlags` Info.plist section hack: Plume ships as a real .app bundle,
        // which carries its own plist. Quill needed the hack because it ran as a bare
        // LaunchAgent binary — and Spike A showed that approach records silence anyway
        // unless launched by launchd.
        .executableTarget(name: "plume", dependencies: ["PlumeKit"]),
        .testTarget(name: "PlumeKitTests", dependencies: ["PlumeKit"]),
    ]
)
