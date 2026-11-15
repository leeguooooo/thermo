import Foundation
import SwiftUI

package struct SelectedDocument:Sendable {
    package enum Kind:Sendable {case file,directory}
    package let path:String
    package let name:String
    package let kind:Kind
    package init(path:String,name:String,kind:Kind){self.path=path;self.name=name;self.kind=kind}
}

/// Selected-document presentation hides resource acquisition, sandbox transport and scene ownership.
@MainActor package protocol DocumentPreviewPresentation:AnyObject {
    func content(selection:SelectedDocument,roots:[String],request:UUID)->AnyView
    func stop(ifCurrent:UUID?)
    /// Joins native input and retirement work; does not promise renderer PID disappearance.
    func finishStopping() async
}
@MainActor package protocol DocumentPreviewService:AnyObject {
    func makePresentation(available:@escaping @MainActor ()->Bool)->any DocumentPreviewPresentation
}
