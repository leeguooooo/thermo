// fixture-entry-installs-composition
// Actual composed MainWindow/registration and DiskScanner, confined to one owned installer.
@testable import ThermoShell
@testable import ThermoComposition
@testable import DiskFeature
import AppKit
import CleanKit
import CryptoKit
import Darwin
import Foundation
import ModuleKit
import NativeFeatureAPI
import SystemServicesAPI

@MainActor private final class DiskReviewState {
    weak var model:DiskModel?
    var created=0
}
private struct DiskReviewFactory:ShellFeatureFactory {
    let home:String
    let state:DiskReviewState
    func makeAssembly(environment:@escaping @MainActor @Sendable ()->ShellFeatureEnvironment)->ShellFeatureAssembly {
        let base=BuiltinFeatureFactory().makeAssembly(environment:environment)
        let definition=DiskFeature.makeRegistration(services:{DiskHostServices(environment:environment())},makeSession:{available,services,cache in
            DiskSession(availability:available,services:services,cache:cache,makeDisk:{cache,work in
                let io=DiskScanIO(options:{scope,category,_ in
                    var options=ScanOptions(projectRoots:[])
                    options.home=home;options.discoverProjectRoots=false;options.olderThanDays=0;options.onlyIDs=["old-installers"]
                    options.categories=category.map{[$0]} ?? (scope == .ai ? [.aiSessions]:[.system])
                    return options
                },cached:DiskScanIO.live.cached,scan:DiskScanIO.live.scan)
                let model=DiskModel(scanIO:io,requestNotifications:{},enabled:{available.acceptsWork},cache:cache,explanationWork:work)
                state.model=model;state.created+=1
                return model
            })
        })
        return .init(definitions:base.definitions.map{$0.manifest.id==BuiltinModuleManifests.disk.id ? definition:$0},
                     makeSearchAccess:base.makeSearchAccess,makeCaptureControl:base.makeCaptureControl)
    }
}
@MainActor private final class DiskReviewDelegate:NSObject,NSApplicationDelegate {
    let root:URL,state:DiskReviewState
    private var timer:Timer?
    init(root:URL,state:DiskReviewState){self.root=root;self.state=state}
    func applicationDidFinishLaunching(_ notification:Notification){
        Settings.register();ModuleCenter.shared.start(prewarmBuiltins:false)
        let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu()
        for (title,action,key) in [("Show disk QA",#selector(showDisk),"o"),("Switch disk module",#selector(toggleDisk),"t"),("Quit disk QA",#selector(NSApplication.terminate(_:)),"q")]{
            let entry=commands.addItem(withTitle:title,action:action,keyEquivalent:key);entry.target=action == #selector(NSApplication.terminate(_:)) ? NSApp:self
        }
        item.submenu=commands;menu.addItem(item);NSApp.mainMenu=menu
        showDisk();installStandardMenus()
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.record()}}
        print("DISK_QA actual registration/MainWindow/DiskScanner; owned home; only old-installers; no notification permission request");fflush(stdout)
    }
    @objc func showDisk(){
        MainWindow.show(.native(.init(BuiltinModuleManifests.disk.id,"scan")))
        MainWindow.window?.title="Thermo Disk Registry QA — one owned installer";NSApp.activate(ignoringOtherApps:true)
    }
    @objc func toggleDisk(){let id=BuiltinModuleManifests.disk.id;ModuleCenter.shared.setEnabled(id,!ModuleCenter.shared.isOn(id));record()}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        ShellState.shared.nativeFeatures.quitBlocker()==nil ? .terminateNow:.terminateCancel
    }
    func applicationWillTerminate(_ notification:Notification){timer?.invalidate();ShellState.shared.nativeFeatures.shutdown();record()}
    private func record(){
        let model=state.model
        let value:[String:Any]=["at":Date().timeIntervalSince1970,"home":NSHomeDirectory(),"modelsCreated":state.created,
            "enabled":ModuleCenter.shared.isOn(BuiltinModuleManifests.disk.id),"modelLoaded":ShellState.shared.nativeFeatures.status(BuiltinModuleManifests.disk.id).modelLoaded,
            "scanning":model?.scanning ?? false,"cleaning":model?.cleaning ?? false,"items":model?.report?.items.map(\.id) ?? [],
            "canaryExists":FileManager.default.fileExists(atPath:root.appendingPathComponent("home/Downloads/thermo-owned-qa.dmg").path)]
        guard var data=try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) else{return};data.append(10)
        let file=root.appendingPathComponent("disk-samples.jsonl")
        if let h=try? FileHandle(forWritingTo:file){defer{try? h.close()};_=try? h.seekToEnd();try? h.write(contentsOf:data)}else{try? data.write(to:file)}
    }
}
@main private struct DiskRegistryReviewMain {
    @MainActor static func main()throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("dev.thermo.shell-review.")==true,
              Bundle.main.object(forInfoDictionaryKey:"ThermoReviewOnly") as?Bool == true,
              let path=Bundle.main.object(forInfoDictionaryKey:"ThermoShellFixtureRoot") as?String else{exit(2)}
        let root=URL(fileURLWithPath:path),home=root.appendingPathComponent("home")
        guard root.lastPathComponent.hasPrefix("thermo-shell-review-"),root.pathExtension=="noindex",
              FileManager.default.fileExists(atPath:home.appendingPathComponent(".thermo-shell-fixture-home").path) else{exit(3)}
        setenv("CFFIXED_USER_HOME",home.path,1)
        guard URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath()==home.resolvingSymlinksInPath() else{exit(4)}
        let fm=FileManager.default,canary=home.appendingPathComponent("Downloads/thermo-owned-qa.dmg"),marker=root.appendingPathComponent("installer-created.json")
        if !fm.fileExists(atPath:marker.path){
            try fm.createDirectory(at:canary.deletingLastPathComponent(),withIntermediateDirectories:true)
            guard !fm.fileExists(atPath:canary.path) else{exit(5)}
            let data=Data(("Thermo owned registry QA installer\n"+String(repeating:"q",count:4096)).utf8)
            try data.write(to:canary,options:.withoutOverwriting)
            let receipt:[String:String]=["path":canary.path,"SHA256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()]
            try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys).write(to:marker)
        }
        _=freopen(root.appendingPathComponent("trace.log").path,"a",stdout)
        let state=DiskReviewState();ShellApplication.install(factory:DiskReviewFactory(home:home.path,state:state))
        let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=DiskReviewDelegate(root:root,state:state);app.delegate=delegate
        DispatchQueue.main.asyncAfter(deadline:.now()+1800){app.terminate(nil)}
        withExtendedLifetime(delegate){app.run()}
    }
}
