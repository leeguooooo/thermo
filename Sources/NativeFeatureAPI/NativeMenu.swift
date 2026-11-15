import SwiftUI

package enum NativeMenuPlacement:Sendable {case application,status,popover,review}
@MainActor package struct NativeMenuAction {
    package let title:String
    package let symbol:String?
    package let enabled:Bool
    private let invoke:()->Void
    package init(title:String,symbol:String? = nil,enabled:Bool = true,perform:@escaping ()->Void){self.title=title;self.symbol=symbol;self.enabled=enabled;invoke=perform}
    package func perform(){if enabled{invoke()}}
}
@MainActor package indirect enum NativeMenuNode {
    case action(NativeMenuAction)
    case submenu(title:String,symbol:String?,items:[NativeMenuNode])
    case separator
}
@MainActor package struct NativeMenuRenderer {
    private let render:([NativeMenuNode])->AnyView
    package init(render:@escaping ([NativeMenuNode])->AnyView){self.render=render}
    package func callAsFunction(_ nodes:[NativeMenuNode])->AnyView{render(nodes)}
}
/// A snapshot for AppKit and an observing feature view for SwiftUI share the same private menu tree.
@MainActor package struct NativeMenuContent {
    private let snapshot:(NativeMenuPlacement)->[NativeMenuNode]
    private let mount:(NativeMenuPlacement,NativeMenuRenderer)->AnyView
    package init(items:@escaping (NativeMenuPlacement)->[NativeMenuNode],view:@escaping (NativeMenuPlacement,NativeMenuRenderer)->AnyView){snapshot=items;mount=view}
    package func items(_ placement:NativeMenuPlacement)->[NativeMenuNode]{snapshot(placement)}
    package func view(_ placement:NativeMenuPlacement,renderer:NativeMenuRenderer)->AnyView{mount(placement,renderer)}
}

extension NativeMenuContent {
    func scoped(to availability:FeatureAvailability,generation:UUID)->Self {
        checkedContent(available:{availability.acceptsWork},generation:generation)
    }
    func checkedContent(available:@escaping @MainActor ()->Bool,generation:UUID)->Self {
        .init(items:{placement in
            guard available() else{return []}
            var remaining=512
            return Self.checked(snapshot(placement),available:available,remaining:&remaining) ?? []
        },view:{placement,renderer in
            guard available() else{return AnyView(EmptyView())}
            let checked=NativeMenuRenderer{nodes in
                guard available() else{return AnyView(EmptyView())}
                var remaining=512
                guard let nodes=Self.checked(nodes,available:available,remaining:&remaining) else{return AnyView(EmptyView())}
                return renderer(nodes)
            }
            return AnyView(mount(placement,checked).id(generation))
        })
    }
    private static func checked(_ nodes:[NativeMenuNode],available:@escaping @MainActor ()->Bool,remaining:inout Int,depth:Int = 0)->[NativeMenuNode]? {
        guard depth<=8,nodes.count<=remaining else{return nil}
        remaining-=nodes.count
        var result:[NativeMenuNode]=[]
        for node in nodes {
            switch node {
            case let .action(action):
                guard action.title.count<=512,(action.symbol?.count ?? 0)<=128 else{return nil}
                result.append(.action(.init(title:action.title,symbol:action.symbol,enabled:action.enabled,perform:{guard available() else{return};action.perform()})))
            case let .submenu(title,symbol,items):
                guard title.count<=512,(symbol?.count ?? 0)<=128,let children=checked(items,available:available,remaining:&remaining,depth:depth+1) else{return nil}
                result.append(.submenu(title:title,symbol:symbol,items:children))
            case .separator:result.append(.separator)
            }
        }
        return result
    }
}
