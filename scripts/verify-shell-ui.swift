// fixture-entry-installs-composition
// Real composed window, isolated preferences/home. No app-control server or optional prewarming.
@testable import ThermoShell
import ThermoComposition
import AppKit
import Darwin
import Foundation
import ModuleKit
import NativeFeatureAPI
import SystemServicesAPI

@MainActor private final class ShellReviewDelegate:NSObject,NSApplicationDelegate {
    let root:URL
    private var timer:Timer?
    init(root:URL){self.root=root}
    func applicationDidFinishLaunching(_ notification:Notification){
        Settings.register()
        let menu=NSMenu(),item=NSMenuItem(),commands=NSMenu()
        for (title,action,key) in [("Show QA console",#selector(showConsole),"o"),("Switch performance",#selector(togglePerformance),"t"),("Quit Shell QA",#selector(NSApplication.terminate(_:)),"q")]{
            let entry=commands.addItem(withTitle:title,action:action,keyEquivalent:key)
            entry.target=action == #selector(NSApplication.terminate(_:)) ? NSApp:self
        }
        item.submenu=commands;menu.addItem(item);NSApp.mainMenu=menu
        ModuleCenter.shared.start(prewarmBuiltins:false)
        // Set the recorder's read-only mode before any Overview view is mounted.
        ShellState.shared.nativeFeatures.start(BuiltinModuleManifests.performance.id)
        showConsole();installStandardMenus()
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.record()}}
        print("SHELL_QA actual MainWindow; isolated home; performance actions/history and automatic helper interaction disabled");fflush(stdout)
    }
    @objc func showConsole(){
        MainWindow.show()
        MainWindow.window?.title="Thermo Shell QA — isolated home"
        NSApp.activate(ignoringOtherApps:true)
    }
    @objc func togglePerformance(){
        let id=BuiltinModuleManifests.performance.id
        ModuleCenter.shared.setEnabled(id,!ModuleCenter.shared.isOn(id));record()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{false}
    func applicationWillTerminate(_ notification:Notification){
        timer?.invalidate();ShellState.shared.nativeFeatures.shutdown();record()
        print("SHELL_QA_EXIT");fflush(stdout)
    }
    private func record(){
        let store=ShellState.shared.nativeFeatures,readers=store.status(BuiltinModuleManifests.performance.id).readers
        let route=MainWindow.state.page.nativeRoute
        let value:[String:Any]=[
            "at":Date().timeIntervalSince1970,"pid":getpid(),"home":NSHomeDirectory(),
            "page":route.map{$0.module+":"+$0.entry} ?? "settings","windowVisible":MainWindow.state.visible,
            "performanceEnabled":ModuleCenter.shared.isOn(BuiltinModuleManifests.performance.id),
            "cpuSampling":readers["cpu"]?.sampling ?? false,"gpuSampling":readers["gpu"]?.sampling ?? false,
            "memorySampling":readers["memory"]?.sampling ?? false,"pulseSampling":readers["pulse"]?.sampling ?? false,
            "pulseHolders":readers["pulse"]?.holders ?? 0,"historyRecording":readers["history"]?.sampling ?? false,
            "performanceActionsEnabled":false,"automaticHelperInteraction":false,"appControlServer":false]
        guard var data=try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys) else{return};data.append(10)
        let file=root.appendingPathComponent("samples.jsonl")
        if let handle=try? FileHandle(forWritingTo:file){defer{try? handle.close()};_=try? handle.seekToEnd();try? handle.write(contentsOf:data)}else{try? data.write(to:file)}
    }
}

@main private struct ShellReviewMain {
    @MainActor static func main(){
        guard Bundle.main.bundleIdentifier?.hasPrefix("dev.thermo.shell-review.")==true,
              Bundle.main.object(forInfoDictionaryKey:"ThermoReviewOnly") as? Bool == true,
              let path=Bundle.main.object(forInfoDictionaryKey:"ThermoShellFixtureRoot") as?String else{exit(2)}
        let root=URL(fileURLWithPath:path),home=root.appendingPathComponent("home").path
        guard root.lastPathComponent.hasPrefix("thermo-shell-review-"),root.pathExtension=="noindex",
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-shell-fixture").path),
              FileManager.default.fileExists(atPath:home+"/.thermo-shell-fixture-home") else{exit(3)}
        setenv("CFFIXED_USER_HOME",home,1)
        guard URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath().path==URL(fileURLWithPath:home).resolvingSymlinksInPath().path else{exit(4)}
        _=freopen(root.appendingPathComponent("trace.log").path,"a",stdout)
        ThermoComposition.install()
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=ShellReviewDelegate(root:root);app.delegate=delegate
        DispatchQueue.main.asyncAfter(deadline:.now()+1800){app.terminate(nil)}
        withExtendedLifetime(delegate){app.run()}
    }
}
