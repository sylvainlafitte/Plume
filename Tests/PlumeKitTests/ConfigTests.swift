import Foundation
import Testing

@testable import PlumeKit

// Placeholder coverage proving the library target is reachable from tests.
// The real coverage lives in the marker-region and speaker-attribution suites.
@Suite("Config")
struct ConfigTests {
    @Test("default root is ~/Meetings, not Quill's ~/Recordings")
    func defaultRoot() {
        #expect(Config.defaultRoot.lastPathComponent == "Meetings")
    }

    @Test("config lives under ~/.config/plume")
    func configPath() {
        #expect(Config.path.path.hasSuffix(".config/plume/config.json"))
    }

    @Test("resolveRoot falls back to the default when nothing is configured")
    func resolveRootFallback() {
        // Only meaningful when the developer has no config file; skip if they do.
        guard !FileManager.default.fileExists(atPath: Config.path.path) else { return }
        #expect(Config.resolveRoot(cliOverride: nil) == Config.defaultRoot)
    }
}
