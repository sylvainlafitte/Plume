// swift-tools-version:6.0
import PackageDescription

// Spike A — does a process get its own TCC identity for system-audio capture?
// Deliberately has no dependencies and no embedded Info.plist: the bare shell run is
// the negative control. The .app bundle assembled by make-app.sh carries the real plist.
let package = Package(
    name: "spike-responsible-process",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SpikeA", path: "Sources/SpikeA")
    ]
)
