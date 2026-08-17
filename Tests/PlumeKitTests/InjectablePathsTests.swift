import Foundation
import Testing

@testable import PlumeKit

/// The two regression tests named in "The refactor pass" as blocked. Both were
/// impossible while `Config.path` and `TemplateStore.directory` were `let`
/// constants pointing at the developer's real files — running them would have
/// rewritten the config and templates of whoever ran `swift test`.
@Suite("Injectable paths")
struct InjectablePathsTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A model changed in the config file must reach the *next* generation.
    ///
    /// This is the regression that `SummaryEngine` holding no `OllamaClient`
    /// exists to prevent: a client built at launch pins the model configured
    /// then, while Settings and the readiness caption both report the
    /// current one — and the stale name gets stamped into `meeting.md` as
    /// provenance.
    @Test("a model changed in config is visible to the next read")
    func configChangeIsPickedUp() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")

        try Config.withPath(file) {
            try #"{"summary_model":"first-model"}"#.write(to: file, atomically: true, encoding: .utf8)
            #expect(Config.summaryModel() == "first-model")

            // The mtime cache is the thing under test as much as the path: a
            // second read must not serve the first file's answer.
            try #"{"summary_model":"second-model"}"#.write(to: file, atomically: true, encoding: .utf8)
            #expect(Config.summaryModel() == "second-model")
        }
    }

    @Test("the override is restored, so one test cannot leak into the next")
    func pathIsRestored() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = Config.path
        Config.withPath(dir.appendingPathComponent("config.json")) {
            #expect(Config.path != before)
        }
        #expect(Config.path == before)
        #expect(Config.path == Config.defaultPath)
    }

    /// An **in-place** edit of an existing template must be picked up. This is
    /// why `TemplateStore` fingerprints the files' own mtimes rather than the
    /// directory's: a directory's mtime changes only when an entry is added or
    /// removed, so a directory-keyed cache would serve the old prompt forever —
    /// and "editing a template is opening the file" is the type's whole premise.
    @Test("an in-place template edit is picked up")
    func templateEditIsPickedUp() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try TemplateStore.withDirectory(dir) {
            let file = dir.appendingPathComponent("general.md")
            try "---\nname: General\n---\n\nFirst instruction.".write(
                to: file, atomically: true, encoding: .utf8)
            #expect(TemplateStore.template(id: "general")?.prompt == "First instruction.")

            // Same file, same name, new contents — the directory's own mtime
            // does not change here, which is exactly the case that used to fail.
            try "---\nname: General\n---\n\nSecond instruction.".write(
                to: file, atomically: true, encoding: .utf8)
            #expect(TemplateStore.template(id: "general")?.prompt == "Second instruction.")
        }
    }

    @Test("a hand-added template file appears without a restart")
    func addedTemplateIsPickedUp() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try TemplateStore.withDirectory(dir) {
            _ = TemplateStore.all()  // seeds, and warms the cache
            try "---\nname: Retro\n---\n\nSummarise a retrospective.".write(
                to: dir.appendingPathComponent("retro.md"), atomically: true, encoding: .utf8)
            #expect(TemplateStore.all().contains { $0.id == "retro" })
        }
    }

    @Test("seeding never overwrites a template that already exists")
    func seedingPreservesEdits() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try TemplateStore.withDirectory(dir) {
            let file = dir.appendingPathComponent("general.md")
            try "---\nname: General\n---\n\nMy own words.".write(
                to: file, atomically: true, encoding: .utf8)
            try TemplateStore.seedIfNeeded()
            #expect(TemplateStore.template(id: "general")?.prompt == "My own words.")
        }
    }
}
