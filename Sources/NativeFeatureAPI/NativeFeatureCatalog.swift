import Foundation
import ModuleKit

package enum NativeContextValue: Hashable, Sendable {
    case text(String), integer(Int64), boolean(Bool)
    var kind: NativeContextKind {
        switch self { case .text: return .text; case .integer: return .integer; case .boolean: return .boolean }
    }
}
package enum NativeContextKind: Equatable, Sendable { case text, integer, boolean }
package struct NativeContextField: Sendable {
    package let name: String
    package let kind: NativeContextKind
    package let defaultValue: NativeContextValue?
    package let required: Bool
    package init(_ name: String, kind: NativeContextKind, defaultValue: NativeContextValue? = nil, required: Bool = true) {
        self.name=name;self.kind=kind;self.defaultValue=defaultValue;self.required=required
    }
}
package struct NativePageContract: Sendable {
    package let entry: String
    package let fields: [NativeContextField]
    package let optionFields: [NativeContextField]
    let checkOptions: @Sendable ([String:NativeContextValue]) throws -> Void
    let check: @Sendable ([String:NativeContextValue]) throws -> Void
    package init(entry:String,fields:[NativeContextField] = [],optionFields:[NativeContextField] = [],checkOptions:@escaping @Sendable ([String:NativeContextValue]) throws -> Void = {_ in},check:@escaping @Sendable ([String:NativeContextValue]) throws -> Void = {_ in}) {
        self.entry=entry;self.fields=fields;self.optionFields=optionFields;self.checkOptions=checkOptions;self.check=check
    }
}
package struct NativeUIEntryRef: Hashable, Sendable {
    package let module:String
    package let entry:String
    package init(_ module:String,_ entry:String) {self.module=module;self.entry=entry}
}
package struct NativeMenuEntry: Identifiable, Sendable {
    package let ref:NativeUIEntryRef
    package let title:String
    package let symbol:String
    package let shortcut:String
    package let hasContent:Bool
    package var id:NativeUIEntryRef {ref}
}
package struct NativeRouteError: Error, LocalizedError {
    package let description:String
    package init(_ description:String){self.description=description}
    package var errorDescription:String? {description}
}

/// Immutable metadata and actor-bound factory values. Parsing never invokes a factory.
package struct NativeFeatureCatalog: Sendable {
    let definitions:[String:NativeFeatureDefinition]
    let order:[String]
    package init(definitions:[NativeFeatureDefinition]) throws {
        guard Set(definitions.map{$0.manifest.id}).count == definitions.count else {
            throw NativeRouteError("Duplicate native feature.")
        }
        let nativeIDs=Set(definitions.map{$0.manifest.id})
        var workers=Set<String>()
        for definition in definitions {
            for worker in definition.privateWorkers {
                guard !worker.isEmpty,!nativeIDs.contains(worker),workers.insert(worker).inserted else {
                    throw NativeRouteError("A private worker must have exactly one native feature owner.")
                }
            }
        }
        guard definitions.filter({$0.ui.compactPanelEntry != nil}).count <= 1 else {
            throw NativeRouteError("Only one native feature may own the compact panel.")
        }
        for definition in definitions {
            guard definition.menuShortcuts.allSatisfy({key,value in value.count==1 && definition.manifest.entries.contains{$0.id==key && $0.kind == .menuBarItem}}) else{throw NativeRouteError("Invalid native menu shortcut.")}
            if !definition.ui.sidebarLocations.isEmpty || definition.ui.hasBackdrop {
                guard definition.manifest.entries.contains(where:{$0.kind == .page}) else{throw NativeRouteError("Native sidebar and backdrop contributions require declared pages.")}
            }
            if definition.ui.hasMenuContent && !definition.manifest.entries.contains(where:{$0.kind == .menuBarItem}) {throw NativeRouteError("Native menu content requires a declared menu entry.")}
            let contracts=definition.pageContracts
            guard Set(contracts.map(\.entry)).count == contracts.count else {throw NativeRouteError("Duplicate native page contract.")}
            for contract in contracts {
                guard definition.manifest.entries.contains(where:{$0.id==contract.entry && $0.kind == .page}) else {
                    throw NativeRouteError("A native page contract must name a declared page.")
                }
                for fields in [contract.fields,contract.optionFields] {
                guard Set(fields.map(\.name)).count == fields.count else {throw NativeRouteError("Duplicate native context field.")}
                for field in fields {
                    guard !field.name.isEmpty,field.name.unicodeScalars.allSatisfy({CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"}),
                          field.defaultValue == nil || field.defaultValue?.kind == field.kind else {
                        throw NativeRouteError("Invalid native context field or default.")
                    }
                }
                }
            }
        }
        self.definitions=Dictionary(uniqueKeysWithValues:definitions.map{($0.manifest.id,$0)})
        order=definitions.map{$0.manifest.id}
        for definition in definitions {
            if let entry=definition.ui.compactPanelEntry {
                _ = try normalize(.init(definition.manifest.id,entry))
            }
        }
    }
    package func manifest(_ id:String)->ModuleManifest? {definitions[id]?.manifest}
    package var manifests:[ModuleManifest] {order.compactMap{definitions[$0]?.manifest}}
    package func privateWorkers(_ id:String)->Set<String> {definitions[id]?.privateWorkers ?? []}
    package func workerOwner(_ worker:String)->ModuleManifest? {
        manifests.first{definitions[$0.id]?.privateWorkers.contains(worker)==true}
    }
    package func normalize(_ input:NativeFeatureRoute)throws->NativeFeatureRoute {
        guard let definition=definitions[input.module],definition.manifest.entries.contains(where:{$0.id==input.entry && $0.kind == .page}) else {
            throw NativeRouteError("Unknown feature page.")
        }
        let contract=definition.pageContracts.first{$0.entry==input.entry}
        let context=try Self.validate(input.context,fields:contract?.fields ?? [])
        try contract?.check(context)
        return .init(input.module,input.entry,context:context)
    }
    private static func validate(_ input:[String:NativeContextValue],fields:[NativeContextField])throws->[String:NativeContextValue] {
        let names=Set(fields.map(\.name))
        guard input.keys.allSatisfy({names.contains($0)}) else {throw NativeRouteError("This page does not accept that context.")}
        var values=input
        for field in fields {
            if values[field.name] == nil {values[field.name]=field.defaultValue}
            if let value=values[field.name] {
                guard value.kind == field.kind else {throw NativeRouteError("Invalid page value: \(field.name).")}
            } else if field.required {throw NativeRouteError("Missing page value: \(field.name).")}
        }
        return values
    }
    package func normalizePresentation(_ input:NativePresentationRequest)throws->NativePresentationRequest {
        let route=try normalize(input.route)
        let contract=definitions[route.module]?.pageContracts.first{$0.entry==route.entry}
        let options=try Self.validate(input.options,fields:contract?.optionFields ?? [])
        try contract?.checkOptions(options)
        return .init(route:route,options:options)
    }
    package func resolveLegacyPage(_ argument:String)throws->NativeFeatureRoute? {
        var found:NativeFeatureRoute?
        for id in order {
            guard let definition=definitions[id],let route=definition.resolveLegacyPage(argument) else{continue}
            guard route.module==id else{throw NativeRouteError("A legacy page must belong to its feature.")}
            let normalized=try normalize(route)
            guard found == nil || found == normalized else{throw NativeRouteError("Ambiguous legacy feature page.")}
            found=normalized
        }
        return found
    }
    func accepts(_ ref:NativeUIEntryRef)->Bool {
        definitions[ref.module]?.manifest.entries.contains(where:{$0.id==ref.entry && ($0.kind == .menuBarItem || $0.kind == .settingsItem)}) == true
    }
    package var menuEntries:[NativeMenuEntry] {
        order.flatMap {id in
            guard let definition=definitions[id] else{return [NativeMenuEntry]()}
            return definition.manifest.entries.filter{$0.kind == .menuBarItem}.map {
                NativeMenuEntry(ref:.init(id,$0.id),title:$0.title,symbol:$0.symbol ?? definition.manifest.symbol,shortcut:definition.menuShortcuts[$0.id] ?? "",hasContent:definition.ui.hasMenuContent)
            }
        }
    }
}

package struct NativePresentationRequest: Sendable {
    package let route:NativeFeatureRoute
    package let options:[String:NativeContextValue]
    package init(route:NativeFeatureRoute,options:[String:NativeContextValue] = [:]) {self.route=route;self.options=options}
}
package struct NativeNavigation: Sendable {
    private let showBody:@MainActor @Sendable (NativePresentationRequest)->Bool
    private let admissionBody:@MainActor @Sendable (NativeFeatureRoute)->Bool
    package init(canAdmit:@escaping @MainActor @Sendable (NativeFeatureRoute)->Bool = {_ in false},show:@escaping @MainActor @Sendable (NativePresentationRequest)->Bool){admissionBody=canAdmit;showBody=show}
    /// A policy-only query; it never constructs or presents the destination feature.
    @MainActor package func canAdmit(_ route:NativeFeatureRoute)->Bool{admissionBody(route)}
    @MainActor package func show(_ request:NativePresentationRequest)->Bool {showBody(request)}
    @MainActor package func show(_ route:NativeFeatureRoute)->Bool {showBody(.init(route:route))}
    package static let unavailable=NativeNavigation(show:{_ in false})
}
