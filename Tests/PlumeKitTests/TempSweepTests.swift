import Foundation
import Testing

@testable import PlumeKit

@Suite("Temp sweep")
struct TempSweepTests {

    private let name = "fluidaudio-streaming-8B0E1F2A.raw"

    @Test("an abandoned conversion older than the guard is swept")
    func sweepsOldScratchFiles() {
        #expect(TempSweep.isStale(name: name, age: TempSweep.minimumAge + 1))
    }

    /// The guard exists because `temporaryDirectory` is shared and a conversion
    /// may be running right now — our own, or a second Plume on a synced folder.
    /// Deleting a live run's backing file would fail the transcription it
    /// belongs to.
    @Test("a file young enough to belong to a running conversion is left alone")
    func sparesRecentFiles() {
        #expect(!TempSweep.isStale(name: name, age: 5))
        #expect(!TempSweep.isStale(name: name, age: TempSweep.minimumAge - 1))
    }

    /// Everything else in that directory belongs to someone else.
    @Test("only FluidAudio's own naming is touched", arguments: [
        "important.raw",
        "fluidaudio-streaming-8B0E1F2A.txt",
        "com.apple.something",
        "fluidaudio.raw",
        "",
    ])
    func ignoresForeignFiles(name: String) {
        #expect(!TempSweep.isStale(name: name, age: 999_999))
    }

    @Test("sweeping a directory removes the stale file and nothing else")
    func endToEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stale = dir.appendingPathComponent(name)
        let foreign = dir.appendingPathComponent("someone-elses.raw")
        try Data().write(to: stale)
        try Data().write(to: foreign)

        // Age both files by asking the sweep to run in the future, rather than
        // backdating mtimes — same policy, no clock games.
        let removed = TempSweep.run(in: dir, now: Date().addingTimeInterval(TempSweep.minimumAge + 60))
        #expect(removed == [name])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}
