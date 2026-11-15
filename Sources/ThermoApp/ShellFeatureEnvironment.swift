import AppKit
import DocumentPreviewAPI
import Foundation
import NativeFeatureAPI
import SystemServicesAPI

/// Only composition receives this host environment. Each feature receives its own narrow contract.
@MainActor package final class ShellFeatureEnvironment {
    private let readDefaults:()->UserDefaults
    private let readTelemetry:()->any TelemetryReadService
    private let readAdministration:()->any HelperAdministration
    private let readFanFactory:()->any FanPolicyAccessFactory
    private let readStore:()->NativeFeatureStore?

    private init(defaults:@escaping ()->UserDefaults,telemetry:@escaping ()->any TelemetryReadService,
                 administration:@escaping ()->any HelperAdministration,fanFactory:@escaping ()->any FanPolicyAccessFactory,
                 store:@escaping ()->NativeFeatureStore?) {
        readDefaults=defaults;readTelemetry=telemetry;readAdministration=administration;readFanFactory=fanFactory;readStore=store
    }
    package static var current:ShellFeatureEnvironment {
        .init(defaults:{AppModels.shared.preferences},telemetry:{AppModels.shared.services.telemetry},
              administration:{AppModels.shared.services.helper},fanFactory:{AppModels.shared.services.helper},
              store:{AppModels.shared.nativeFeatures})
    }
    package static func referencing(_ store:NativeFeatureStore)->ShellFeatureEnvironment {
        .init(defaults:{AppModels.shared.preferences},telemetry:{AppModels.shared.services.telemetry},
              administration:{AppModels.shared.services.helper},fanFactory:{AppModels.shared.services.helper},store:{[weak store] in store})
    }
    static func bound(defaults:UserDefaults,services:AppSystemServices,store:@escaping ()->NativeFeatureStore?)->ShellFeatureEnvironment {
        .init(defaults:{defaults},telemetry:{services.telemetry},administration:{services.helper},fanFactory:{services.helper},store:store)
    }
    package var defaults:UserDefaults {readDefaults()}
    package var telemetry:any TelemetryReadService {readTelemetry()}
    package var administration:any HelperAdministration {readAdministration()}
    package var fanFactory:any FanPolicyAccessFactory {readFanFactory()}
    package var nativeFeatures:NativeFeatureStore? {readStore()}
    package var mainWindowActive:Bool {MainWindow.window?.isKeyWindow == true}
    package var actionsAllowed:Bool {!AppLaunchMode.suppressesAutomaticControl(arguments:CommandLine.arguments)}
    @discardableResult package func open(_ request:NativePresentationRequest)->Bool {MainWindow.showRegistered(request)}
    @discardableResult package func select(_ route:NativeFeatureRoute)->Bool {
        guard let checked=try? BuiltinNativeFeatures.catalog.normalize(route),NSApp.modalWindow==nil,MainWindow.window?.attachedSheet==nil else{return false}
        MainWindow.show(.native(checked));return true
    }
    package func showSettings(){MainWindow.show(.settings)}
    package func showSearchSettings(){_=SearchHost.show(settings:true)}
    package func closeMenuPanel(){(NSApp.delegate as? AppDelegate)?.closeMenuPanel()}
    package func requestScanNotifications(){SystemPresentation.requestNotificationPermission()}
    package func previewService(worker:String)->any DocumentPreviewService {SearchPreviewServices.service(worker:worker)}
    package func openTrash(){NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))}
    package func reveal(_ path:String){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])}
    package func protectRemoval(onQuit:@escaping @MainActor ()->Void)->any ShellQuitProtection {
        let token=AppExitGuard.beginManualRemoval(onQuit:onQuit)
        return HostQuitProtection{AppExitGuard.endManualRemoval(token)}
    }
    package func protectRestore()->any ShellQuitProtection {
        let token=AppExitGuard.beginRestore()
        return HostQuitProtection{AppExitGuard.endRestore(token)}
    }
}

@MainActor final class ShellFeatureStoreReference {weak var store:NativeFeatureStore?}

@MainActor package protocol ShellQuitProtection:AnyObject {func finish()}
@MainActor private final class HostQuitProtection:ShellQuitProtection {
    private var release:(@MainActor ()->Void)?
    init(release:@escaping @MainActor ()->Void){self.release=release}
    func finish(){let body=release;release=nil;body?()}
    deinit{if let release {Task{@MainActor in release()}}}
}
