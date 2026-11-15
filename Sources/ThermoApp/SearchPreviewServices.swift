import DocumentPreviewHost
import DocumentPreviewAPI
import ThermoL10n

@MainActor enum SearchPreviewServices {
    private static var services:[String:any DocumentPreviewService]=[:]
    static func service(worker:String)->any DocumentPreviewService {
        if let value=services[worker]{return value}
        let center=ModuleCenter.shared
        let value=SandboxedDocumentPreviewService(manager:center.manager,worker:worker,loaded:{center.loaded},statuses:center.$statuses.eraseToAnyPublisher(),restartRequired:{
            AppInstallationMonitor.shared.check()
            return AppInstallationMonitor.shared.needsRestart ? tr("An update is installed. Restart Thermo to use it."):nil
        })
        services[worker]=value;return value
    }
}
