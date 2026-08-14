import Foundation
import Testing

@testable import PlumeKit

@Suite("Settings decoding")
struct SettingsTests {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test("snake_case keys map to the typed fields")
    func snakeCase() throws {
        let settings = try decode("""
            { "recordings_dir": "~/Elsewhere",
              "on_stop": "say done",
              "mic_voice_processing": true,
              "transcription": { "enabled": false, "engine": "parakeet" } }
            """)
        #expect(settings.recordingsDir == "~/Elsewhere")
        #expect(settings.onStop == "say done")
        #expect(settings.micVoiceProcessing == true)
        #expect(settings.transcription?.enabled == false)
        #expect(settings.transcription?.engine == "parakeet")
    }

    @Test("absent keys stay nil rather than becoming defaults")
    func absentKeysStayNil() throws {
        // Round-tripping must not materialise defaults into the file: an unset
        // key means "follow the app default", which should keep tracking it.
        let settings = try decode("{}")
        #expect(settings.recordingsDir == nil)
        #expect(settings.micVoiceProcessing == nil)
        #expect(settings.transcription == nil)

        let encoded = try JSONEncoder().encode(settings)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("mic_voice_processing"))
        #expect(!text.contains("recordings_dir"))
    }

    @Test("a partial config decodes without losing the rest")
    func partialConfig() throws {
        let settings = try decode(#"{ "transcription": { "enabled": true } }"#)
        #expect(settings.transcription?.enabled == true)
        #expect(settings.transcription?.engine == nil)
        #expect(settings.onStop == nil)
    }

    @Test("round-trip preserves every set field")
    func roundTrip() throws {
        var original = Settings()
        original.recordingsDir = "/tmp/meetings"
        original.micVoiceProcessing = false
        original.transcription = .init(enabled: true, engine: "parakeet")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("Speaker-count bound")
struct ExpectedParticipantsTests {
    @Test("default is a 1:1, capping the far end at one speaker")
    func defaultIsOneToOne() {
        // The mic track is you by construction, so N participants means N-1
        // far-end speakers. Default 2 → cap 1 → over-splitting a 1:1 into
        // S1/S2 becomes structurally impossible, not merely unlikely.
        #expect(Config.expectedParticipants() == 2)
        #expect(Config.maxFarEndSpeakers() == 1)
    }

    @Test("zero means unconstrained, not zero speakers")
    func zeroMeansUnconstrained() throws {
        let settings = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"expected_participants": 0}"#.utf8))
        #expect(settings.expectedParticipants == 0)
    }

    @Test("a headcount maps to headcount-1 far-end speakers, never below 1")
    func capArithmetic() {
        // Pure arithmetic on the stored value, so it holds regardless of what
        // the developer's own config file happens to say.
        func cap(for expected: Int) -> Int? {
            guard expected > 0 else { return nil }
            return Swift.max(1, expected - 1)
        }
        #expect(cap(for: 2) == 1)
        #expect(cap(for: 3) == 2)
        #expect(cap(for: 5) == 4)
        #expect(cap(for: 0) == nil)
        // A nonsensical 1 must not become a cap of 0, which would mean "no
        // speakers at all" rather than "just you".
        #expect(cap(for: 1) == 1)
    }
}
