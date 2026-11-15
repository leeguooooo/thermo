import SwiftUI

/// A plain page: the shared header, then its content, scrolling.
package struct WindowPage<Trailing: View, Content: View>: View {
    package init(title:String,subtitle:String? = nil,@ViewBuilder trailing:@escaping ()->Trailing,@ViewBuilder content:@escaping ()->Content) {self.title=title;self.subtitle=subtitle;self.trailing=trailing;self.content=content}
    let title: String
    var subtitle: String? = nil
    /// Page-wide actions sit beside the title, as on Apps and Skills, not on a row of their own.
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    package var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: title, subtitle: subtitle, trailing: trailing, below: { EmptyView() })
                content()
            }
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

extension WindowPage where Trailing == EmptyView {
    package init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

