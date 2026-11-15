import Foundation
import CaptureScriptCore

package struct CaptureControlRequest:Sendable {
    package enum Operation:Sendable {case actions,status(UUID?),cancel(UUID?),run(String),action(String)}
    package let id:UUID
    package let operation:Operation
    package let dryRun:Bool
    package init(id:UUID,operation:Operation,dryRun:Bool = false){self.id=id;self.operation=operation;self.dryRun=dryRun}
}
/// Request success is separate from a queried operation's recorded phase.
package struct CaptureControlResult:Sendable {
    package let report:CaptureCLIReport
    package let succeeded:Bool
    package init(report:CaptureCLIReport,succeeded:Bool){self.report=report;self.succeeded=succeeded}
}
@MainActor package protocol CaptureApplicationControl:AnyObject {
    func handle(_ request:CaptureControlRequest) async->CaptureControlResult
    func cancelActive()
}
