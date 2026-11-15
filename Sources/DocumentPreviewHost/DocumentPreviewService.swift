import Combine
import DocumentPreviewAPI
import ModuleHost
import SwiftUI

/// One exact manager/worker lifetime owns ordering, independently of consumer sessions.
@MainActor final class DocumentPreviewBroker {
    let manager:ModuleManager
    let worker:String
    let loaded:@MainActor ()->Bool
    let statuses:AnyPublisher<[ModuleManager.Status],Never>
    let restartRequired:@MainActor ()->String?
    var owner:UUID?
    var sequence:UInt64=0
    init(manager:ModuleManager,worker:String,loaded:@escaping @MainActor ()->Bool,statuses:AnyPublisher<[ModuleManager.Status],Never>,restartRequired:@escaping @MainActor ()->String?) {
        self.manager=manager;self.worker=worker;self.loaded=loaded;self.statuses=statuses;self.restartRequired=restartRequired
    }
}
@MainActor package final class SandboxedDocumentPreviewService:DocumentPreviewService {
    private let broker:DocumentPreviewBroker
    package init(manager:ModuleManager,worker:String,loaded:@escaping @MainActor ()->Bool,statuses:AnyPublisher<[ModuleManager.Status],Never>,restartRequired:@escaping @MainActor ()->String?) {
        broker=DocumentPreviewBroker(manager:manager,worker:worker,loaded:loaded,statuses:statuses,restartRequired:restartRequired)
    }
    package func makePresentation(available:@escaping @MainActor ()->Bool)->any DocumentPreviewPresentation {DocumentPreviewController(broker:broker,available:available)}
}
