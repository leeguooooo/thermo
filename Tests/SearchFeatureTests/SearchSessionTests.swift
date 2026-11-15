import AppKit
import Carbon
import DocumentPreviewAPI
import HotkeyCore
import ModuleKit
import NativeFeatureAPI
import SearchCore
import SwiftUI
import XCTest
@testable import SearchFeature

@MainActor final class SearchSessionTests:XCTestCase {
    private let id=BuiltinModuleManifests.search.id
    private final class Lease:CleanScreenHotkeyLease {
        var fail=false,released=false
        func release()throws{if fail{throw NSError(domain:"owned-lease",code:1)};released=true}
    }
    private final class Keys:CleanScreenHotkeyBackend {
        var leases:[Lease]=[],events:[(Bool)->Void]=[]
        func register(_ binding:CleanScreenKeyBinding,event:@escaping (Bool)->Void)throws->CleanScreenHotkeyLease{let value=Lease();leases.append(value);events.append(event);return value}
    }
    private final class Spotlight {
        var released=true,restores=0,takes=0
        var adapter:SpotlightShortcut{.init(commandSpaceTaken:{!self.released},release:{self.released=true;self.takes+=1},restore:{self.released=false;self.restores+=1},released:{self.released},otherHolder:{nil})}
    }
    private final class Preview:DocumentPreviewService,DocumentPreviewPresentation {
        var made=0,stops=0,finishes=0
        func makePresentation(available:@escaping @MainActor ()->Bool)->any DocumentPreviewPresentation{made+=1;return self}
        func content(selection:SelectedDocument,roots:[String],request:UUID)->AnyView{AnyView(EmptyView())}
        func stop(ifCurrent:UUID?){stops+=1}
        func finishStopping() async{finishes+=1}
    }
    private func defaults()->(UserDefaults,String){let name="thermo-search-session-"+UUID().uuidString;return (UserDefaults(suiteName:name)!,name)}
    func testOffRecoveryNeverAdmitsSessionDatabasePanelOrHotkey() throws {
        let (prefs,name)=defaults();defer{prefs.removePersistentDomain(forName:name)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-cold-search-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let keys=Keys(),spotlight=Spotlight(),preview=Preview();var models=0,shortcuts=0
        let registration=SearchFeature.makeRegistration(preview:{preview},makeModel:{enabled in models+=1;return LocalSearchModel(directory:root,enabled:enabled)},makeShortcut:{action in shortcuts+=1;return LocalSearchShortcut(backend:keys,spotlight:spotlight.adapter,defaults:prefs,module:BuiltinModuleManifests.search,action:action,record:{_ in})})
        prefs.set(false,forKey:ModulePreferences.key(id))
        let store=NativeFeatureStore(definitions:[registration.definition],enabled:{_ in false}),access=registration.makeAccess(store)
        XCTAssertTrue(registration.definition.manifest.entries.allSatisfy{$0.kind != .page})
        store.start(id);XCTAssertFalse(access.show(settings:false));XCTAssertFalse(access.takeOverSpotlight().confirmed)
        XCTAssertNil(store.inlineSettings(.init(id,"settings")));XCTAssertNil(store.renderPreview(.init(id,"settings")));XCTAssertNil(try store.prepareStop(id))
        XCTAssertEqual(shortcuts,0);XCTAssertFalse(store.status(id).modelLoaded)
        XCTAssertTrue(access.giveBackSpotlight().confirmed);XCTAssertEqual(spotlight.restores,1)
        XCTAssertEqual(shortcuts,1);XCTAssertEqual(models,0);XCTAssertEqual(preview.made,0);XCTAssertTrue(keys.leases.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testWarmTakeoverAndInlineSettingsStayDatabaseColdAndFailedReleaseIsRetryable() async throws {
        let (prefs,name)=defaults();defer{prefs.removePersistentDomain(forName:name)}
        let keys=Keys(),spotlight=Spotlight(),preview=Preview();spotlight.released=false
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-warm-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var models=0,shortcuts=0
        let registration=SearchFeature.makeRegistration(preview:{preview},makeModel:{_ in models+=1;XCTFail("unexpected database");return LocalSearchModel(directory:root)},makeShortcut:{action in shortcuts+=1;return LocalSearchShortcut(backend:keys,spotlight:spotlight.adapter,defaults:prefs,action:action,record:{_ in})})
        let store=NativeFeatureStore(definitions:[registration.definition],enabled:{_ in true}),access=registration.makeAccess(store)
        XCTAssertNotNil(store.inlineSettings(.init(id,"settings")));XCTAssertEqual(shortcuts,0)
        XCTAssertTrue(access.takeOverSpotlight().confirmed);XCTAssertEqual(keys.leases.count,1);XCTAssertEqual(models,0);XCTAssertEqual(preview.made,0)
        keys.leases[0].fail=true
        XCTAssertThrowsError(try store.prepareStop(id));XCTAssertTrue(store.admitUIEntryOwner(.init(id,"settings")))
        XCTAssertFalse(access.takeOverSpotlight().confirmed);XCTAssertEqual(keys.leases.count,1)
        keys.leases[0].fail=false
        let drain=try XCTUnwrap(store.prepareStop(id))
        XCTAssertFalse(access.takeOverSpotlight().confirmed)
        keys.events[0](false);keys.events[0](true);XCTAssertEqual(models,0)
        await drain.finish();XCTAssertTrue(keys.leases[0].released);XCTAssertEqual(models,0)
        XCTAssertTrue(access.giveBackSpotlight().confirmed);XCTAssertEqual(shortcuts,1)
    }
    func testDialogRefusesBeforeShortcutOrPreviewSideEffects() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-dialog-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var shortcuts=0;let preview=Preview()
        let authority=SearchShortcutAuthority(makeShortcut:{_ in shortcuts+=1;XCTFail("shortcut created on refusal");return LocalSearchShortcut(backend:Keys(),spotlight:Spotlight().adapter,action:{},record:{_ in})})
        let availability=FeatureAvailability{true}
        let session=SearchSession(availability:availability,authority:authority,makeModel:{LocalSearchModel(directory:root,enabled:$0)},preview:{preview})
        session.model.presentingDialog=true
        XCTAssertThrowsError(try session.prepareStop());XCTAssertTrue(availability.acceptsWork);XCTAssertNotNil(session.storedModel?.store)
        XCTAssertEqual(shortcuts,0);XCTAssertEqual(preview.made,0);session.model.stop();await session.model.finishStopping()
    }
    func testAcceptedDisableKeepsPhysicalQueryAndBlocksFreshAdmissionUntilItReturns() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-drain-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let entered=expectation(description:"physical query entered"),reader=SearchModuleLifecycleTests.Reader(entered)
        defer{reader.release.signal()}
        let preview=Preview(),authority=SearchShortcutAuthority(makeShortcut:{_ in XCTFail("unexpected key registration");return LocalSearchShortcut(backend:Keys(),spotlight:Spotlight().adapter,action:{},record:{_ in})})
        var sessions:[SearchSession]=[]
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.search,makeSession:{availability in
            let s=SearchSession(availability:availability,authority:authority,makeModel:{LocalSearchModel(directory:root,enabled:$0,executeQuery:{term,_ in reader.query(term)})},preview:{preview});authority.current=s;sessions.append(s);return s
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true}),ref=NativeUIEntryRef(id,"settings")
        XCTAssertTrue(store.admitUIEntryOwner(ref));let old=sessions[0];old.model.query="old"
        await fulfillment(of:[entered],timeout:2)
        let drain=try XCTUnwrap(store.prepareStop(id)),finish=Task{await drain.finish()}
        await Task.yield();XCTAssertFalse(store.admitUIEntryOwner(ref));XCTAssertNotNil(old.storedModel?.store)
        XCTAssertEqual(sessions.count,1);XCTAssertGreaterThan(old.storedModel?.activeQueries ?? 0,0)
        reader.release.signal();await finish.value
        XCTAssertNil(old.storedModel);XCTAssertTrue(store.admitUIEntryOwner(ref));XCTAssertEqual(sessions.count,2);XCTAssertNil(sessions[1].storedModel)
        XCTAssertEqual(preview.made,0)
    }
}
