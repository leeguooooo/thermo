import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n
import ThermoUI
import UniformTypeIdentifiers

/// Export and import of which built-in features are on and how they are set up (#50).
struct SetupShareControls:View {
    @ObservedObject var center:ModuleCenter
    @State private var pending:PendingImport?
    @State private var problem:String?
    var body:some View {
        HStack(spacing:Theme.Space.s){
            Button(tr("Export setup…")){export()}.buttonStyle(PillButtonStyle())
                .accessibilityIdentifier("module-center-export-setup")
            Button(tr("Import setup…")){choose()}.buttonStyle(PillButtonStyle())
                .accessibilityIdentifier("module-center-import-setup")
        }
        .sheet(item:$pending){item in SetupImportReview(center:center,review:item.review){pending=nil}}
        .alert(tr("Can't use this file"),isPresented:Binding(get:{problem != nil},set:{if !$0{problem=nil}})){
            Button(tr("OK")){problem=nil}
        } message:{Text(problem ?? "")}
    }
    private func export() {
        let panel=NSSavePanel()
        panel.nameFieldStringValue="Thermo setup.json";panel.allowedContentTypes=[.json]
        panel.message=tr("Contains which features are on and their settings. No personal data, paths or keys.")
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try SetupShare.encode(SetupShare.export(NativeModules.all,from:.standard)).write(to:url,options:.atomic)}
        catch {problem=error.localizedDescription}
    }
    private func choose() {
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let data=try Data(contentsOf:url)
            pending=.init(review:try SetupShare.review(data,manifests:NativeModules.all,current:.standard))
        } catch SetupShare.ReadError.newerVersion {
            problem=tr("This setup was exported by a newer Thermo. Update Thermo first.")
        } catch {
            problem=tr("This is not a Thermo setup file.")
        }
    }
    struct PendingImport:Identifiable {let id=UUID();let review:SetupShare.Review}
}

struct SetupImportReview:View {
    @ObservedObject var center:ModuleCenter
    let review:SetupShare.Review
    let done:()->Void
    private func name(_ id:String)->String {NativeModules.manifest(id).map{tr($0.name)} ?? id}
    var body:some View {
        VStack(alignment:.leading,spacing:Theme.Space.m){
            Text(tr("Import setup")).font(Theme.heading)
            ScrollView{
                VStack(alignment:.leading,spacing:Theme.Space.m){
                    if review.isEmpty {Text(tr("This setup matches yours. Nothing would change.")).foregroundStyle(Theme.textSecondary)}
                    if !review.switchOn.isEmpty {
                        Text(tr("Features to switch on")).font(Theme.body.weight(.semibold))
                        ForEach(review.switchOn,id:\.self){id in
                            VStack(alignment:.leading,spacing:2){
                                Text(name(id))
                                ForEach(ShellNativeCatalog.catalog.permissionDescriptions(id),id:\.self){Text(tr($0)).font(Theme.secondary).foregroundStyle(Theme.textSecondary)}
                            }
                        }
                    }
                    if !review.switchOff.isEmpty {
                        Text(tr("Features to switch off")).font(Theme.body.weight(.semibold))
                        ForEach(review.switchOff,id:\.self){Text(name($0))}
                    }
                    if !review.settings.isEmpty {
                        Text(tr("%1$@ settings will change.",String(review.settings.count))).foregroundStyle(Theme.textSecondary)
                    }
                    if !review.ignored.isEmpty {
                        Text(tr("%1$@ entries this version doesn't know are skipped.",String(review.ignored.count))).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:320)
            HStack{
                Spacer()
                Button(tr("Cancel"),role:.cancel){done()}.keyboardShortcut(.cancelAction)
                Button(tr("Import")){
                    SetupShare.applySettings(review,to:.standard)
                    for id in review.switchOff {center.setEnabled(id,false)}
                    for id in review.switchOn {center.setEnabled(id,true)}
                    done()
                }.keyboardShortcut(.defaultAction).disabled(review.isEmpty)
            }
        }.padding(Theme.Space.l).frame(width:420)
    }
}
