import DocumentPreviewHost
import DocumentPreviewAPI
import SearchFeature
import ThermoL10n

@MainActor enum SearchPreviewServices {
    static let service: any DocumentPreviewService = {
        let center=ModuleCenter.shared
        return SandboxedDocumentPreviewService(manager:center.manager,worker:SearchFeature.previewWorkerID,loaded:{center.loaded},statuses:center.$statuses.eraseToAnyPublisher(),restartRequired:{
            AppInstallationMonitor.shared.check()
            return AppInstallationMonitor.shared.needsRestart ? tr("An update is installed. Restart Thermo to use it."):nil
        })
    }()
}
