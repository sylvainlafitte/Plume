import Foundation

/// The one safe folder reconciliation boundary.
///
/// The app wraps this in a synchronous MainActor handoff that flushes and
/// updates both UI surfaces. The CLI calls it directly because it has no models
/// holding the old path.
enum MeetingSummaryFinalizer {
    @discardableResult
    static func finalize(session: URL) throws -> URL {
        do {
            try MeetingTitleStore.reconcileUserTitle(in: session)
        } catch {
            // SummaryEngine has already written a good summary and advanced
            // state. Missing legacy metadata may cost title reconciliation, but
            // must not turn that success into a failure-shaped result.
            FileHandle.standardError.write(Data(
                "could not reconcile meeting title: \(error)\n".utf8))
        }
        guard let title = MeetingTitleStore.title(in: session) else { return session }
        return MeetingAdmin.renameFolder(session, toSlugOf: title)
    }
}
