// swift-tools-version:6.0
import PackageDescription

// Spike B — can a non-activating floating panel accept typed text while another app
// stays frontmost, and is it excluded from screen shares?
let package = Package(
    name: "spike-panel",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SpikeB", path: "Sources/SpikeB")
    ]
)
