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
            ("0.1.0", "0.0.9"),
            // Tag spellings that must not change the answer.
            ("v0.2.0", "0.1.0"),
            ("0.2.0", "v0.1.0"),
            // Build metadata is not part of precedence.
            ("0.2.0+build.7", "0.1.0"),
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
            ("0.1.0+build.9", "0.1.0"),
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
        ])
    func notNewer(remote: String, local: String) {
        #expect(!UpdateCheck.isNewer(remote, than: local))
    }

    /// A prerelease of the next version is not the next version. `/releases/latest`
    /// already excludes prereleases, so this is the second line of defence — it
    /// only matters if a prerelease is ever marked as the latest release by hand.
    @Test("a prerelease sorts below the release it precedes")
    func prereleaseOrdering() {
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.2.0-rc.1"))
        #expect(!UpdateCheck.isNewer("0.2.0-rc.1", than: "0.2.0"))
        // But it is still newer than the version it follows.
        #expect(UpdateCheck.isNewer("0.2.0-rc.1", than: "0.1.0"))
    }

    // MARK: - Parsing the API's answer

    private func payload(
        tag: String = "v0.2.0",
        url: String = "https://github.com/sylvainlafitte/Plume/releases/tag/v0.2.0",
        extra: String = ""
    ) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)"\#(extra)}"#.utf8)
    }

    @Test("a normal release yields its version and page")
    func parsesRelease() throws {
        let release = try #require(UpdateCheck.release(from: payload()))
        // The leading v is stripped: it is a tag convention, not the version.
        #expect(release.version == "0.2.0")
        #expect(release.url.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    }

    /// The URL is the release *page*. Pointing at the asset would start a
    /// download the user did not ask for, and Plume never installs anything.
    @Test("the page is what is offered, not the asset")
    func pointsAtThePage() throws {
        let release = try #require(UpdateCheck.release(from: payload()))
        #expect(!release.url.absoluteString.hasSuffix(".zip"))
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

    @Test("a newer release reaches the caller")
    func reportsUpdate() async throws {
        let found = await UpdateCheck.availableUpdate(
            local: "0.1.0", fetch: { self.payload() })
        #expect(try #require(found).version == "0.2.0")
    }

    @Test("the current version reports nothing")
    func silentWhenCurrent() async {
        let found = await UpdateCheck.availableUpdate(
            local: "0.2.0", fetch: { self.payload() })
        #expect(found == nil)
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
    /// That is the difference between a privacy claim and a UI preference.
    @Test("switched off, nothing is even fetched")
    func offMeansNoRequest() throws {
        let (found, fetched) = withUpdateCheckDisabled { probe in
            await UpdateCheck.availableUpdate(
                local: "0.1.0", fetch: { probe.called = true; return self.payload() })
        }
        #expect(found == nil)
        #expect(!fetched, "the setting must gate the request, not the result")
    }

    /// Settings' **Check now** asks even with the setting off, because the press
    /// is the request — the same consent-by-click rule as the call-detection
    /// notification. Without this, the button would report "up to date" having
    /// asked nobody, which is the one thing this feature must never do.
    @Test("Check now asks even when automatic checks are off")
    func explicitCheckBypassesTheSetting() throws {
        let (found, fetched) = withUpdateCheckDisabled { probe in
            await UpdateCheck.availableUpdate(
                local: "0.1.0", honoringSetting: false,
                fetch: { probe.called = true; return self.payload() })
        }
        #expect(fetched, "an explicit check must actually ask")
        #expect(found?.version == "0.2.0")
    }

    /// Records whether the fetch closure ran. A class box because the closure is
    /// `@Sendable`.
    final class Probe: @unchecked Sendable { var called = false }

    /// Runs `body` against a config file with `update_check: false`.
    ///
    /// `Config.withPath` is synchronous, so the async call is bridged *inside* the
    /// closure: a `Task` created there inherits the task-local override, one
    /// created outside would not see it at all — and the test would then pass for
    /// the wrong reason on a machine whose real config happens to disable this.
    private func withUpdateCheckDisabled(
        _ body: @escaping @Sendable (Probe) async -> UpdateCheck.Release?
    ) -> (UpdateCheck.Release?, Bool) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plume-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try? Data(#"{"update_check":false}"#.utf8).write(to: config)

        let probe = Probe()
        let found = Config.withPath(config) { () -> UpdateCheck.Release? in
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: UpdateCheck.Release?
            Task {
                result = await body(probe)
                semaphore.signal()
            }
            semaphore.wait()
            return result
        }
        return (found, probe.called)
    }
}
