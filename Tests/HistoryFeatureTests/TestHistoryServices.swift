import Foundation
import CleanKit
import XCTest
@testable import HistoryFeature

@MainActor final class TestHistoryServices: HistoryServices {
    nonisolated let reader: @Sendable () -> OperationJournal.ReadReport
    nonisolated let reviewer: @Sendable (String) throws -> TrashRestore
    nonisolated let restore: @Sendable (String, TrashRestore) throws -> TrashRestore
    let didRestore: @MainActor ([String]) -> Void
    var journalURL: URL { URL(fileURLWithPath: "/fixture/history") }
    init(reader: @escaping @Sendable () -> OperationJournal.ReadReport = { .init(records: []) },
         reviewer: @escaping @Sendable (String) throws -> TrashRestore = { _ in throw NSError(domain: "fixture", code: 1) },
         restore: @escaping @Sendable (String, TrashRestore) throws -> TrashRestore = { _, _ in throw NSError(domain: "fixture", code: 1) },
         didRestore: @escaping @MainActor ([String]) -> Void = { _ in }) {
        self.reader=reader;self.reviewer=reviewer;self.restore=restore;self.didRestore=didRestore
    }
    nonisolated func read() -> OperationJournal.ReadReport { reader() }
    nonisolated func reviewRestore(batch: String) throws -> TrashRestore { try reviewer(batch) }
    func beginRestore(batch: String, review: TrashRestore) throws -> any HistoryRestoration {
        let restore=restore
        return TestRestoration(run: { try restore(batch,review) }, didRestore: didRestore)
    }
    func followUp(for record: OperationRecord) -> HistoryFollowUp? { nil }
}
@MainActor private final class TestRestoration: HistoryRestoration {
    private let run: @Sendable () throws -> TrashRestore
    private let didRestore: @MainActor ([String]) -> Void
    private var cancelled=false
    init(run: @escaping @Sendable () throws -> TrashRestore,didRestore: @escaping @MainActor ([String]) -> Void) {self.run=run;self.didRestore=didRestore}
    func cancelBeforeStart(){cancelled=true}
    func perform() async throws -> TrashRestore {
        guard !cancelled else {throw CancellationError()}
        let run=run
        let result=try await Task.detached {try run()}.value
        let paths=result.items.filter{$0.status == "restored"}.map(\.original)
        if !paths.isEmpty {didRestore(paths)}
        return result
    }
}
extension HistoryModel {
    convenience init(enabled: @escaping () -> Bool = {true},
         reader: @escaping @Sendable () -> OperationJournal.ReadReport = {.init(records:[])},
         reviewBatch: @escaping @Sendable (String) throws -> TrashRestore = {_ in throw NSError(domain:"fixture",code:1)},
         restoreBatch: @escaping @Sendable (String,TrashRestore) throws -> TrashRestore = {_,_ in throw NSError(domain:"fixture",code:1)},
         didRestore: @escaping @MainActor ([String]) -> Void = {_ in}) {
        self.init(enabled:enabled,services:TestHistoryServices(reader:reader,reviewer:reviewBatch,restore:restoreBatch,didRestore:didRestore))
    }
}
