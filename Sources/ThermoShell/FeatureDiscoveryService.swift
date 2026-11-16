import Foundation
import ModuleKernelCore
import ModuleKit
import NativeFeatureAPI
import ThermoL10n

/// Uses catalogue metadata and the existing switch authority, never a feature factory.
@MainActor final class FeatureDiscoveryService:FeatureDiscoveryAccess {
    private let center:ModuleCenter
    private let defaults:UserDefaults
    private let catalog:NativeFeatureCatalog
    static let suggestionsKey="module.discovery.recommendations.enabled"
    static let seenKey="module.discovery.recommendations.seen"
    init(center:ModuleCenter,defaults:UserDefaults,catalog:NativeFeatureCatalog) {
        self.center=center;self.defaults=defaults;self.catalog=catalog
    }
    var recommendationsEnabled:Bool {
        get {(defaults.object(forKey:Self.suggestionsKey) as? Bool) ?? true}
        set {defaults.set(newValue,forKey:Self.suggestionsKey)}
    }
    func matches(_ query:String)->[FeatureDiscoveryItem] {
        let terms=Self.normalized(query).split(whereSeparator:{$0.isWhitespace}).map(String.init)
        guard terms.joined().count>=2 else{return []}
        return center.switches.compactMap { status in
            guard !status.enabled else{return nil}
            let manifest=status.manifest.localized(L10n.current.rawValue)
            let words=Self.normalized(([status.manifest.name,status.manifest.summary]+([manifest.name,manifest.summary]+manifest.entries.map(\.title)).map{tr($0)}).joined(separator:" "))
            guard terms.allSatisfy(words.contains) else{return nil}
            return item(status.manifest,builtin:status.builtin)
        }
    }
    private static func normalized(_ text:String)->String {
        text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }
    private func item(_ original:ModuleManifest,builtin:Bool)->FeatureDiscoveryItem {
        let manifest=original.localized(L10n.current.rawValue)
        var permissions=original.capabilities.map { capability in
            ModuleCapabilityText.title(capability.kind)+(capability.scope.map{" · "+$0} ?? "")
        }
        if builtin {
            permissions.insert(tr("Built-in features share Thermo's system permissions."),at:0)
            permissions += catalog.permissionDescriptions(original.id).map{tr($0)}
        } else if permissions.isEmpty {permissions=[tr("No separate module access is declared.")]}
        return .init(id:manifest.id,name:tr(manifest.name),summary:tr(manifest.summary),symbol:manifest.symbol,
                     storage:tr(builtin ? "Built into Thermo · no additional download":"Already installed · no additional download"),permissions:permissions)
    }
    func enable(_ reviewed:FeatureDiscoveryItem)throws {
        let id=reviewed.id
        guard let status=center.switches.first(where:{$0.manifest.id==id}) else{throw NativeFeatureBusy(tr("This feature is no longer available."))}
        if status.enabled{return}
        guard item(status.manifest,builtin:status.builtin)==reviewed else{throw NativeFeatureBusy(tr("Feature access changed. Review it again before enabling."))}
        guard !center.changing.contains(id) else{throw NativeFeatureBusy(tr("Wait for this feature to finish switching off."))}
        center.setEnabled(id,true)
        guard center.isOn(id) else{throw NativeFeatureBusy(center.switchIssues[id] ?? tr("This feature could not be enabled."))}
    }
    func claimRecommendation(_ id:String)->FeatureDiscoveryItem? {
        guard recommendationsEnabled,let status=center.switches.first(where:{$0.manifest.id==id}),!status.enabled else{return nil}
        var seen=Set(defaults.stringArray(forKey:Self.seenKey) ?? [])
        guard seen.insert(id).inserted else{return nil}
        defaults.set(seen.sorted(),forKey:Self.seenKey)
        return item(status.manifest,builtin:status.builtin)
    }
}
