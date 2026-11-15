import AppKit
import ModuleKit
import SwiftUI
import XCTest
@testable import NativeFeatureAPI

@MainActor final class NativePageMountTests:XCTestCase {
    private final class Selection:ObservableObject {
        @Published var entry="first"
        @Published var revision=0
    }
    private struct Page:View {
        let entry:String
        let appeared:(String)->Void
        let disappeared:(String)->Void
        var body:some View{Text(entry).onAppear{appeared(entry)}.onDisappear{disappeared(entry)}}
    }
    private struct Host:View {
        @ObservedObject var selection:Selection
        let store:NativeFeatureStore
        let id:String
        var body:some View{let _=selection.revision;store.page(.init(id,selection.entry))}
    }
    private final class Session:NativeFeatureSession {
        let generation:Int
        let appeared:(String)->Void
        let disappeared:(String)->Void
        init(_ generation:Int,appeared:@escaping(String)->Void,disappeared:@escaping(String)->Void){self.generation=generation;self.appeared=appeared;self.disappeared=disappeared}
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{AnyView(Page(entry:"\(generation):\(route.entry)",appeared:appeared,disappeared:disappeared))}
        var status:NativeFeatureStatus{.init(modelLoaded:true)}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func testSameViewTypeGetsANewVisibilityLifecycleForAnotherRouteAndGeneration() async throws {
        _=NSApplication.shared
        let first=expectation(description:"first route appeared"),second=expectation(description:"new route appeared"),replacement=expectation(description:"new generation appeared")
        var appearances:[String]=[],disappearances:[String]=[],made=0
        let manifest=ModuleManifest(id:"com.example.mount",name:"Mount",summary:"",symbol:"doc",version:"1.0.0",entries:[
            .init(id:"first",kind:.page,title:"First",scene:"first"),.init(id:"second",kind:.page,title:"Second",scene:"second")])
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{_ in
            made+=1;return Session(made,appeared:{entry in
                appearances.append(entry)
                if appearances.filter({$0==entry}).count==1 {
                    switch entry{case "1:first":first.fulfill();case "1:second":second.fulfill();case "2:second":replacement.fulfill();default:break}
                }
            },disappeared:{disappearances.append($0)})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),selection=Selection()
        let window=NSWindow(contentRect:.init(x:-6000,y:-6000,width:250,height:120),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer{window.contentViewController=nil;window.orderOut(nil)}
        window.contentViewController=NSHostingController(rootView:Host(selection:selection,store:store,id:manifest.id))
        window.orderBack(nil)
        await fulfillment(of:[first],timeout:2)
        selection.entry="second"
        await fulfillment(of:[second],timeout:2)
        XCTAssertTrue(disappearances.contains("1:first"))
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        selection.revision+=1
        await fulfillment(of:[replacement],timeout:2)
        XCTAssertTrue(disappearances.contains("1:second"))
        XCTAssertEqual(appearances,["1:first","1:second","2:second"])
    }
}
