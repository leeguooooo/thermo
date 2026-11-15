import Foundation
import CleanKit

/// Trusted host capabilities. Journal ownership, global restore protection and follow-up routing
/// remain outside this presentation module.
@MainActor package protocol HistoryServices: AnyObject {
    var journalURL: URL { get }
    nonisolated func read() -> OperationJournal.ReadReport
    nonisolated func reviewRestore(batch: String) throws -> TrashRestore
    func beginRestore(batch: String, review: TrashRestore) throws -> any HistoryRestoration
    func followUp(for record: OperationRecord) -> HistoryFollowUp?
}

/// Admission is synchronous. A skipped worker must abandon its unstarted operation; an admitted
/// physical restore runs to completion even if the caller requests cancellation later.
@MainActor package protocol HistoryRestoration: AnyObject {
    func perform() async throws -> TrashRestore
    func cancelBeforeStart()
}

@MainActor package struct HistoryFollowUp {
    package let title: String
    package let symbol: String?
    package let perform: () -> Void
    package init(title: String, symbol: String? = nil, perform: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.perform = perform
    }
}
