import Foundation

/// Existing resource recovery can outlive ordinary enabled sessions. Projections must stay inert.
@MainActor package struct NativeRetainedMenu {
    package let owner:NativeUIEntryRef
    package let content:NativeMenuContent
    package init(owner:NativeUIEntryRef,content:NativeMenuContent){self.owner=owner;self.content=content}
}
package struct NativeRetainedContributions:Sendable {
    let menu:@MainActor @Sendable ()->NativeRetainedMenu?
    let shutdown:@MainActor @Sendable ()->Void
    package init(menu:@escaping @MainActor @Sendable ()->NativeRetainedMenu? = {nil},shutdown:@escaping @MainActor @Sendable ()->Void = {}){self.menu=menu;self.shutdown=shutdown}
    package static let none=Self()
}
