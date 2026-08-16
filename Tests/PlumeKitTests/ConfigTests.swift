import Foundation
import Testing

@testable import PlumeKit

// Placeholder coverage proving the library target is reachable from tests.
// Real coverage arrives with the marker-region and speaker-attribution work
// (docs/PLAN.md, Verification).
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

@Suite("Recording disclosure (R4)")
struct DisclosureTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the default says what is recorded, that it stays local, and offers an out")
    func defaultWording() {
        let text = Config.disclosureText()
        #expect(text.lowercased().contains("recording"))
        // "Nothing is uploaded" is the claim that makes this honest rather than
        // boilerplate, and it is the same claim the README must never break.
        #expect(text.lowercased().contains("uploaded"))
        // Notice alone is not consent; the out is what makes it a real offer in
        // a two-party-consent jurisdiction.
        #expect(text.lowercased().contains("rather i didn't"))
        #expect(!text.contains("\n"))
    }

    @Test("a configured disclosure replaces the default")
    func configuredWording() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")

        try Config.withPath(file) {
            try #"{"disclosure_text":"Ceci est enregistré."}"#
                .write(to: file, atomically: true, encoding: .utf8)
            #expect(Config.disclosureText() == "Ceci est enregistré.")
        }
    }

    @Test("an empty configured disclosure falls back rather than copying nothing")
    func emptyFallsBack() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")

        try Config.withPath(file) {
            try #"{"disclosure_text":"   "}"#.write(to: file, atomically: true, encoding: .utf8)
            // Copying an empty string would look like the button was broken.
            #expect(!Config.disclosureText().isEmpty)
        }
    }
}
