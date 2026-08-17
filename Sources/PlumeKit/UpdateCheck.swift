import Foundation

/// Asks GitHub whether a newer release exists, and never does anything else.
///
/// **Why this exists at all.** Plume ships outside the App Store, so nothing on
/// the machine will ever tell you a new version is out. Someone who downloaded
/// a zip has no mechanism whatsoever.
///
/// **Why it is this small.** No appcast, no EdDSA key, no self-replacing bundle.
/// The one thing that ships is: a menu-bar line that appears only when an update
/// exists, and a click that opens the release page. Downloading and swapping the
/// bundle is Sparkle's job and Sparkle's failure modes; downloading the new zip
/// and dragging it to /Applications already works.
///
/// **The privacy cost is real and is the reason for the toggle.** This is the
/// only outbound request Plume makes that is not localhost and not the one-time
/// model download, so it is the one claim in the README that this feature could
/// falsify. It is therefore kept to the minimum that still works: an anonymous
/// GET of a public JSON document, at most once a day, sending no identifier and
/// no report of what is installed beyond the `User-Agent` any HTTP request
/// carries. It is off in one toggle (`update_check`), and off means *no request
/// is constructed* rather than a request whose result is ignored.
///
/// Everything that decides *whether to tell the user* is pure and tested. The
/// network call cannot be, so it is deliberately the thinnest part: fetch, hand
/// the bytes to `release(from:)`, and treat every failure as "no update" —
/// there is no error state to show, because a failed update check is not a
/// problem the user has.
public enum UpdateCheck {

    /// A published release, as far as this feature cares.
    public struct Release: Sendable, Equatable {
        /// Version as published, with any leading `v` removed.
        public let version: String
        /// The **release page**, never the asset: the page explains what changed,
        /// which is what decides whether you want it at all.
        public let url: URL
    }

    /// `/releases/latest` rather than `/releases`: GitHub defines it to exclude
    /// drafts and prereleases, so an unfinished tag cannot nag anyone. That is a
    /// server-side guarantee we would otherwise have to re-implement here.
    static let endpoint = URL(
        string: "https://api.github.com/repos/sylvainlafitte/Plume/releases/latest")!

    /// Once a day, not once an hour. The thing being watched changes a few times
    /// a year, and this app is a login item that may stay up for weeks — so the
    /// interval is what makes "at most one request a day" a true statement.
    public static let interval: TimeInterval = 60 * 60 * 24

    /// This build's user-facing version, from `CFBundleShortVersionString`.
    ///
    /// Deliberately not `CFBundleVersion`: that is the commit count, which the
    /// releases API knows nothing about. Falls back to "0.0.0" outside a bundle
    /// (the CLI, and tests), which compares older than any release — harmless,
    /// because nothing outside the app ever calls the network path.
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Pure

    /// Parsed form of a version string: dotted non-negative integers, nothing
    /// else. Two components are enough for this project, but a third is common,
    /// so any number of them is accepted.
    ///
    /// **Refusing to parse must mean "say nothing"**, never "assume newer": the
    /// failure mode of guessing is a permanent, un-dismissable "update
    /// available" line pointing at a release that may not exist. So anything
    /// with a prerelease or build suffix (`1.0.0-rc.1`, `1.0.0+build`) is simply
    /// refused rather than ranked. `/releases/latest` already excludes
    /// prereleases and `release(from:)` re-checks the flag, so a tag reaching
    /// here with a suffix means something is off — and silence is the safe
    /// answer to that, not a comparison.
    struct Version: Comparable, Equatable {
        let components: [Int]

        init?(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.first == "v" || text.first == "V" { text.removeFirst() }

            let numbers = text.split(separator: ".").map { Int($0) }
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else {
                return nil
            }
            components = numbers.map { $0! }
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            // Compare positionally, treating a missing component as 0, so
            // "0.2" and "0.2.0" are the same version rather than incomparable.
            for index in 0..<max(lhs.components.count, rhs.components.count) {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    /// True only when `remote` parses, `local` parses, and remote is strictly
    /// newer. Every other combination is false — including equal versions and
    /// anything unparseable on either side.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let remote = Version(remote), let local = Version(local) else { return false }
        return local < remote
    }

    /// A `Release` from the API's JSON, or nil if this isn't a release we should
    /// point anyone at.
    ///
    /// Decoded field by field rather than into a `Codable` struct because the
    /// document has ~40 keys we don't want and the two we do are both optional
    /// in practice: a release with no tag, or an `html_url` that isn't a URL, is
    /// not an error to report — it is a release to ignore.
    static func release(from data: Data) -> Release? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let page = json["html_url"] as? String,
            let url = URL(string: page)
        else { return nil }

        // Belt and braces over the endpoint's own guarantee: if either flag is
        // ever true here, GitHub has changed what `latest` means.
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }

        var version = tag
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        guard Version(version) != nil else { return nil }
        return Release(version: version, url: url)
    }

    // MARK: - Network

    /// The newer release, or nil — including when the check is switched off,
    /// when the network fails, and when we are already current.
    ///
    /// `local` and `fetch` are parameters so the decision is testable without a
    /// bundle and without the network.
    ///
    /// The setting gates the *request*, not the result: off means no request is
    /// constructed at all, which is what makes the README's claim about what
    /// leaves the machine true rather than approximately true.
    static func availableUpdate(
        local: String = currentVersion,
        fetch: @Sendable () async -> Data? = fetchLatest
    ) async -> Release? {
        guard Config.updateCheckEnabled() else { return nil }
        guard let data = await fetch(), let release = release(from: data) else { return nil }
        guard isNewer(release.version, than: local) else { return nil }
        return release
    }

    /// One anonymous GET. Returns nil on anything at all going wrong: a failed
    /// update check is not news, and reporting it would put a scary line in the
    /// menu bar for an offline laptop.
    static func fetchLatest() async -> Data? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        // GitHub answers 403 to some requests with no User-Agent. This is the
        // only thing we tell it about ourselves, and it is what any HTTP client
        // sends; there is no identifier, no machine id, no install count.
        request.setValue("Plume/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Don't let a proxy or the URL cache answer with yesterday's document;
        // the request is once a day, so there is nothing to save.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.write("update check: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return data
        } catch {
            // Offline is the common case and is not worth a line in the log
            // every day; anything else might be.
            if (error as? URLError)?.code != .notConnectedToInternet {
                Log.write("update check failed: \(error.localizedDescription)")
            }
            return nil
        }
    }
}

/// Owns the "when": at launch, then once a day for as long as the app is up.
///
/// Separate from `UpdateCheck` for the same reason `CameraWatch` is separate
/// from the CMIO reads — the policy of *when to look* is the part that has to
/// respect a setting and survive a settings change, and it is main-actor state
/// because what it feeds is the menu bar.
@MainActor
final class UpdateWatch {
    private var timer: Timer?
    private let onFound: (UpdateCheck.Release) -> Void

    /// Long enough that the check never competes with the things launch actually
    /// has to do — the readiness checks, model setup, resuming the transcription
    /// queue — and short enough that it has answered before anyone opens a menu.
    static let launchDelay: TimeInterval = 20

    init(onFound: @escaping (UpdateCheck.Release) -> Void) {
        self.onFound = onFound
    }

    /// Idempotent, so a Settings toggle can just call it again. Turning the
    /// setting off tears the timer down; it does not merely ignore the answer.
    func startIfEnabled() {
        stop()
        guard Config.updateCheckEnabled() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.interval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // A repeating timer's first fire is one interval away, which for a daily
        // interval means a fresh launch would never check at all.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-reads the setting rather than trusting the timer's existence: the
    /// launch-delay task is already in flight by the time a toggle can stop the
    /// timer, so this is the point that has to honour it.
    func check() {
        Task { [onFound] in
            guard let release = await UpdateCheck.availableUpdate() else { return }
            Log.write("update available · \(release.version)")
            onFound(release)
        }
    }
}
