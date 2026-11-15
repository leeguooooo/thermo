import AppKit
import NativeFeatureAPI

/// AppKit owns the final reply; feature tickets own asynchronous finalization.
@MainActor final class NativeTerminationCoordinator {
    private var pending:NativeTerminationTicket?
    private let complete:@MainActor (Bool)->Void
    init(complete:@escaping @MainActor (Bool)->Void = {NSApp.reply(toApplicationShouldTerminate:$0)}){self.complete=complete}
    func reply(after prior:NSApplication.TerminateReply,features:NativeFeatureStore)->NSApplication.TerminateReply {
        guard prior == .terminateNow else{return prior}
        guard pending == nil else{return .terminateLater}
        switch features.prepareTermination() {
        case .allow:return .terminateNow
        case .cancel:return .terminateCancel
        case let .deferred(ticket):
            pending=ticket
            Task{[self] in
                let allowed=await ticket.finish()
                guard pending === ticket else{return}
                pending=nil;complete(allowed)
            }
            return .terminateLater
        }
    }
}
