import AppKit
import CaptureCore
import XCTest
@testable import ThermoApp

@MainActor final class CaptureTranslationModelTests:XCTestCase {
    enum Failure:Error{case fixture}
    final class Secrets:CaptureTranslationSecrets {
        var values:[String:CaptureTranslationCredential]=[:],failRead=false
        func read(_ account:String)throws->CaptureTranslationCredential?{if failRead{throw Failure.fixture};return values[account]}
        func write(_ credential:CaptureTranslationCredential?,account:String)throws{values[account]=credential}
    }
    actor Count {var value=0;func increment(){value += 1};func read()->Int{value}}
    private func profile()->CaptureTranslationSettings{var value=CaptureTranslationSettings();value.provider = .chatCompletions;value.endpoint="http://127.0.0.1:12345/chat";value.model="fixture";value.enabled=true;return value}
    private func wait(_ model:CaptureTranslationModel,seconds:Double=5)async {let deadline=Date().addingTimeInterval(seconds);while model.busy && Date()<deadline{try? await Task.sleep(nanoseconds:10_000_000)};XCTAssertFalse(model.busy)}
    func testSettingsAndCredentialsRollbackAndDisabledDoesNotNeedKeychainAccess() throws {
        let secrets=Secrets();var stored:Data?,fail=false
        let service=CaptureTranslationService(read:{nil},save:{if fail{throw Failure.fixture};stored=$0},secrets:secrets)
        let profile=profile();XCTAssertTrue(service.apply(profile,newCredential:.init(secret:"original-key")))
        let original=stored;fail=true;XCTAssertFalse(service.apply(profile,newCredential:.init(secret:"new-key")));XCTAssertEqual(stored,original);XCTAssertEqual(try secrets.read(profile.credentialAccount)?.secret,"original-key")
        XCTAssertFalse(String(decoding:original!,as:UTF8.self).contains("original-key"))
        fail=false;secrets.failRead=true;var disabled=profile;disabled.enabled=false;XCTAssertTrue(service.apply(disabled,newCredential:nil));XCTAssertFalse(service.settings.enabled)
    }
    func testEndpointChangesCannotReuseSavedCredentialsAndInvalidStoredProfileDoesNotSend() async throws {
        let count=Count(),secrets=Secrets(),client=CaptureTranslationClient(send:{_ in await count.increment();throw Failure.fixture},pause:{})
        let service=CaptureTranslationService(read:{Data("broken".utf8)},save:{_ in},secrets:secrets,client:client)
        do{_=try await service.translate(["hello"]);XCTFail("invalid preferences")}catch{}
        let profile=profile();XCTAssertTrue(service.apply(profile,newCredential:.init(secret:"key")));var other=profile;other.endpoint="http://127.0.0.1:12346/chat"
        XCTAssertFalse(service.apply(other,newCredential:nil));XCTAssertEqual(service.settings,profile);let calls=await count.read();XCTAssertEqual(calls,0)
    }
    func testTextInputDoesNotSendUntilInvokedAndCreatesEditableTextPin() async throws {
        let count=Count(),service=CaptureTranslationService(read:{nil},save:{_ in},secrets:Secrets(),client:.init(send:{_ in await count.increment();return Data(#"{"choices":[{"message":{"content":"[\"你好\"]"},"finish_reason":"stop"}]}"#.utf8)},pause:{}))
        XCTAssertTrue(service.apply(profile(),newCredential:.init(secret:"fake")))
        let model=CaptureTranslationModel(service:service);model.setText("Hello");let before=await count.read();XCTAssertEqual(before,0)
        var pinned="";model.openText={pinned=$0};model.translate();await wait(model);XCTAssertTrue(model.resultReady);XCTAssertEqual(model.translated,"你好");model.createPin();XCTAssertEqual(pinned,"你好")
    }
    func testSettingsChangesDuringLocalOCRKeepRecognizedSource() async throws {
        let service=CaptureTranslationService(read:{nil},save:{_ in},secrets:Secrets())
        let model=CaptureTranslationModel(service:service,recognizeImage:{_ in try await Task.sleep(nanoseconds:50_000_000);return [.init(text:"local source",bounds:CGRect(x:0,y:0,width:1,height:1))]})
        let image=CGContext(data:nil,width:10,height:10,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        model.setImage(image);XCTAssertTrue(model.preparingImage);XCTAssertTrue(service.apply(profile(),newCredential:.init(secret:"fake")));model.configurationChanged();await wait(model)
        XCTAssertEqual(model.source,"local source");XCTAssertFalse(model.preparingImage)
    }
    func testForgettingDraftEndpointDoesNotDeleteActiveEndpointCredential() throws {
        let secrets=Secrets(),service=CaptureTranslationService(read:{nil},save:{_ in},secrets:secrets)
        let active=profile();XCTAssertTrue(service.apply(active,newCredential:.init(secret:"active")))
        var other=active;other.endpoint="http://127.0.0.1:12346/chat";try secrets.write(.init(secret:"other"),account:other.credentialAccount)
        XCTAssertTrue(service.forgetCredential(for:other));XCTAssertEqual(try secrets.read(active.credentialAccount)?.secret,"active");XCTAssertNil(try secrets.read(other.credentialAccount));XCTAssertTrue(service.settings.enabled)
    }
    func testScriptClipboardTranslationUsesConfiguredServiceAndPrivateClipboard() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root))),board=NSPasteboard.withUniqueName()
        defer{workspace.shutdown();board.releaseGlobally();try? FileManager.default.removeItem(at:root)}
        let service=CaptureTranslationService(read:{nil},save:{_ in},secrets:Secrets(),client:.init(send:{_ in Data(#"{"choices":[{"message":{"content":"[\"你好\"]"}}]}"#.utf8)},pause:{}));XCTAssertTrue(service.apply(profile(),newCredential:.init(secret:"fake")))
        workspace.translationService=service;workspace.scriptPasteboard=board;board.setString("Hello",forType:.string)
        let result=try await workspace.performScriptAction("translateClipboard");XCTAssertEqual(result,.string("你好"))
    }
    func testTemporaryTargetDoesNotChangeSavedDefault() async throws {
        let service=CaptureTranslationService(read:{nil},save:{_ in},secrets:Secrets(),client:.init(send:{request in
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],messages=body["messages"] as! [[String:String]];XCTAssertTrue(messages[0]["content"]!.contains("to ja"))
            return Data(#"{"choices":[{"message":{"content":"[\"こんにちは\"]"}}]}"#.utf8)
        },pause:{}));XCTAssertTrue(service.apply(profile(),newCredential:.init(secret:"fake")))
        let model=CaptureTranslationModel(service:service);model.setText("Hello");model.targetLanguage="ja";model.translate();await wait(model)
        XCTAssertEqual(model.translated,"こんにちは");XCTAssertEqual(service.settings.targetLanguage,"zh")
    }
    func testChangedInputAndCancelDiscardLateResponse() async throws {
        let count=Count(),service=CaptureTranslationService(read:{nil},save:{_ in},secrets:Secrets(),client:.init(send:{_ in await count.increment();try await Task.detached{try await Task.sleep(nanoseconds:150_000_000)}.value;return Data(#"{"choices":[{"message":{"content":"[\"late\"]"}}]}"#.utf8)},pause:{}))
        XCTAssertTrue(service.apply(profile(),newCredential:.init(secret:"fake")))
        let model=CaptureTranslationModel(service:service);model.setText("before");model.translate();while await count.read()<1{await Task.yield()};model.source="after";XCTAssertFalse(model.busy)
        try await Task.sleep(nanoseconds:250_000_000);XCTAssertFalse(model.resultReady);XCTAssertTrue(model.translated.isEmpty)
        model.translate();while await count.read()<2{await Task.yield()};model.cancel();try await Task.sleep(nanoseconds:250_000_000);XCTAssertFalse(model.resultReady);XCTAssertFalse(model.busy)
    }
    func testLocalImageOCRDoesNotSendAndOverlayCreatesASeparateImage() async throws {
        _=NSApplication.shared
        let count=Count(),service=CaptureTranslationService(read:{nil},save:{_ in},secrets:Secrets(),client:.init(send:{request in
            await count.increment();let object=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any],messages=object["messages"] as! [[String:String]],source=try JSONDecoder().decode([String].self,from:messages[1]["content"]!.data(using:.utf8)!)
            let result=String(decoding:try JSONEncoder().encode(source.map{_ in "译文"}),as:UTF8.self)
            return try JSONSerialization.data(withJSONObject:["choices":[["message":["content":result]]]])
        },pause:{}));XCTAssertTrue(service.apply(profile(),newCredential:.init(secret:"fake")))
        let ctx=CGContext(data:nil,width:800,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:800,height:200));NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
        ("Hello translation 12345" as NSString).draw(at:CGPoint(x:30,y:80),withAttributes:[.font:NSFont.systemFont(ofSize:48),.foregroundColor:NSColor.black]);NSGraphicsContext.restoreGraphicsState()
        let image=ctx.makeImage()!,model=CaptureTranslationModel(service:service);model.setImage(image);await wait(model,seconds:40);XCTAssertFalse(model.regions.isEmpty);let before=await count.read();XCTAssertEqual(before,0)
        model.mode = .image;model.translate();await wait(model);XCTAssertTrue(model.resultReady)
        var copied:CGImage?;model.openImage={copied=$0};model.createPin();XCTAssertNotNil(copied);XCTAssertFalse(copied === image);XCTAssertEqual(copied?.width,image.width)
    }
    func testPrivateKeychainNamespaceRoundTrip() throws {
        let store=CaptureTranslationKeychain(service:"dev.thermo.translation.fixture."+UUID().uuidString),account="fixture"
        do{try store.write(.init(secret:"not-a-real-key"),account:account)}catch CaptureTranslationFailure.keychain(let code) where [-25291,-25293,-25308,-34018].contains(code){throw XCTSkip("Owned Keychain fixture unavailable: "+String(code))}
        defer{do{try store.write(nil,account:account)}catch{XCTFail("Owned Keychain fixture cleanup failed: "+error.localizedDescription)}}
        XCTAssertEqual(try store.read(account)?.secret,"not-a-real-key")
    }
}
