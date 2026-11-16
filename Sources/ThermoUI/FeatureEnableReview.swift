import SwiftUI
import ThermoL10n

package struct FeatureEnableReview:View {
    let name:String,summary:String,storage:String
    let permissions:[String]
    let enable:()->Void,cancel:()->Void
    package init(name:String,summary:String,storage:String,permissions:[String],enable:@escaping ()->Void,cancel:@escaping ()->Void) {
        self.name=name;self.summary=summary;self.storage=storage;self.permissions=permissions;self.enable=enable;self.cancel=cancel
    }
    package var body:some View {
        VStack(alignment:.leading,spacing:Theme.Space.m) {
            Text(tr("Enable %1$@?",name)).font(Theme.heading)
            Text(summary).font(Theme.body).foregroundStyle(Theme.textSecondary)
            Text(storage).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            Text(tr("Permissions and access")).font(Theme.sectionTitle)
            ForEach(Array(permissions.enumerated()),id:\.offset){_,line in Text(line).font(Theme.secondary).fixedSize(horizontal:false,vertical:true)}
            Text(tr("Enabling makes the feature available. System permission prompts appear only when a tool needs them."))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            HStack {Spacer();Button(tr("Cancel"),action:cancel).keyboardShortcut(.cancelAction).buttonStyle(PillButtonStyle())
                Button(tr("Enable"),action:enable).keyboardShortcut(.defaultAction).buttonStyle(PillButtonStyle(prominent:true))}
        }.padding(Theme.Space.l).frame(width:480).fixedSize(horizontal:false,vertical:true)
    }
}
