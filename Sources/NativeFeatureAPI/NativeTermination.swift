import Foundation

@MainActor package enum NativeTerminationDecision {
    case allow,cancel
    case deferred(NativeTerminationTicket)
}
/// One physical finalization, shared by repeated exit requests. Retains its owner until completion.
@MainActor package final class NativeTerminationTicket {
    private var operation:(@MainActor () async->Bool)?
    private var task:Task<Bool,Never>?
    package private(set) var resolved=false
    package init(operation:@escaping @MainActor () async->Bool){self.operation=operation}
    package func finish() async->Bool {
        if task==nil,let operation {
            self.operation=nil
            task=Task{await operation()}
        }
        let result=await task?.value ?? false
        resolved=true;return result
    }
}
