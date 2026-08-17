import Foundation
import Testing

@testable import PlumeKit

/// The whole decision "should the user be told about a new version", tested
/// without the network. `availableUpdate` takes its fetch as a parameter for
/// exactly this reason.
///
/// The property that matters most here is **asymmetric**, and it is the same one
/// the format-version gate has: anything we cannot read must mean *say nothing*.
/// A false negative is a user who updates a week later; a false positive is a
/// permanent menu-bar line pointing at a release that may not exist, on every
/// launch, with no way to dismiss it.
@Suite("Update check")
struct UpdateCheckTests {

    // MARK: - Comparison

    @Test(
        "a strictly newer version is an update",
        arguments: [
            ("0.1.1", "0.1.0"),
            ("0.2.0", "0.1.9"),
            ("1.0.0", "0.9.9"),
            // Tag spellings that must not change the answer.
            ("v0.2.0", "0.1.0"),
            ("0.2.0", "v0.1.0"),
            // Fewer components on either side means zeros, not incomparable.
            ("0.2", "0.1.9"),
            ("1", "0.9"),
        ])
    func newer(remote: String, local: String) {
        #expect(UpdateCheck.isNewer(remote, than: local))
    }

    @Test(
        "everything that is not strictly newer is not an update",
        arguments: [
            // Equal, in every spelling — the common case, once a day, forever.
            ("0.1.0", "0.1.0"),
            ("v0.1.0", "0.1.0"),
            ("0.1", "0.1.0"),
            ("0.1.0", "0.1"),
            // Older.
            ("0.1.0", "0.1.1"),
            ("0.9.9", "1.0.0"),
            // Unparseable on either side must be silence, never "newer".
            ("", "0.1.0"),
            ("latest", "0.1.0"),
            ("v", "0.1.0"),
            ("0.1.x", "0.1.0"),
            ("-1.0.0", "0.1.0"),
            ("0.1.0", "not-a-version"),
            // Suffixed tags are refused outright rather than ranked. A
            // prerelease or build tag should never reach here — /releases/latest
            // excludes prereleases and `release(from:)` re-checks the flag — so
            // one that does means something is off, and silence is the safe
            // answer to that.
            ("0.2.0-rc.1", "0.1.0"),
            ("0.2.0+build.7", "0.1.0"),
            ("0.2.0", "0.2.0-rc.1"),
        ])
    func notNewer(remote: String, local: String) {
        #expect(!UpdateCheck.isNewer(remote, than: local))
    }

    // MARK: - Parsing the API's answer

    private func payload(
        tag: String = "v0.2.0",
        url: String = "https://github.com/sylvainlafitte/Plume/releases/tag/v0.2.0",
        extra: String = ""
    ) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)"\#(extra)}"#.utf8)
    }

    @Test("a normal release yields its version and its page, not its asset")
    func parsesRelease() throws {
        let release = try #require(UpdateCheck.release(from: payload()))
        // The leading v is stripped: it is a tag convention, not the version.
        #expect(release.version == "0.2.0")
        // The URL is the release *page*. Pointing at the asset would start a
        // download nobody asked for, and Plume never installs anything.
        #expect(release.url.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    }

    @Test(
        "anything that isn't a release we can point at is ignored",
        arguments: [
            // Draft or prerelease: /releases/latest promises it excludes these,
            // so seeing one means GitHub changed the endpoint's meaning.
            #"{"tag_name":"v0.2.0","html_url":"https://x/y","draft":true}"#,
            #"{"tag_name":"v0.2.0","html_url":"https://x/y","prerelease":true}"#,
            // Missing pieces.
            #"{"html_url":"https://x/y"}"#,
            #"{"tag_name":"v0.2.0"}"#,
            // A tag that is not a version — a docs tag, or a moved pointer.
            #"{"tag_name":"nightly","html_url":"https://x/y"}"#,
            // Not JSON at all: a captive-portal login page, an error body.
            "<html>404</html>",
            "",
        ])
    func ignoresNonReleases(json: String) {
        #expect(UpdateCheck.release(from: Data(json.utf8)) == nil)
    }

    // MARK: - The decision as a whole

    @Test("a newer release reaches the caller, the current one does not")
    func reportsOnlyAnUpdate() async throws {
        let found = await UpdateCheck.availableUpdate(
            local: "0.1.0", fetch: { self.payload() })
        #expect(try #require(found).version == "0.2.0")

        let current = await UpdateCheck.availableUpdate(
            local: "0.2.0", fetch: { self.payload() })
        #expect(current == nil)
    }

    /// Offline, rate-limited, DNS-hijacked, 500 — `fetchLatest` collapses them
    /// all to nil, and nil must never become a claim about a new version.
    @Test("a failed fetch is not an update")
    func silentWhenFetchFails() async {
        let found = await UpdateCheck.availableUpdate(local: "0.1.0", fetch: { nil })
        #expect(found == nil)
    }

    /// The setting is checked *before* the fetch closure is called, so "off"
    /// means no request is constructed — not a request whose answer is dropped.
    /// That is the difference between a privacy claim and a UI preference, and
    /// with no "Check now" button there is no second path that could weaken it.
    @Test("switched off, nothing is even fetched")
    func offMeansNoRequest() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plume-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try? Data(#"{"update_check":false}"#.utf8).write(to: config)

        // `Config.withPath` is synchronous, so the async call is bridged *inside*
        // the closure: a `Task` created there inherits the task-local override,
        // one created outside would not see it at all — and the test would then
        // pass for the wrong reason on a machine whose real config disables this.
        let probe = Probe()
        let found = Config.withPath(config) { () -> UpdateCheck.Release? in
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: UpdateCheck.Release?
            Task {
                result = await UpdateCheck.availableUpdate(
                    local: "0.1.0", fetch: { probe.called = true; return self.payload() })
                semaphore.signal()
            }
            semaphore.wait()
            return result
        }
        #expect(found == nil)
        #expect(!probe.called, "the setting must gate the request, not the result")
    }

    /// Records whether the fetch closure ran. A class box because the closure is
    /// `@Sendable`.
    final class Probe: @unchecked Sendable { var called = false }
}
