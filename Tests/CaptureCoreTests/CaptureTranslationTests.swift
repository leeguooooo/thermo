import AppKit
import XCTest
@testable import CaptureCore

final class CaptureTranslationTests:XCTestCase {
    func testSettingsAreDisabledAndCredentialsAreNotSerialized() throws {
        var value=CaptureTranslationSettings();XCTAssertFalse(value.enabled);XCTAssertEqual(try .decode(value.data()),value)
        for endpoint in ["http://example.com/api","https://user:secret@example.com/api","https://example.com/api?key=secret","file:///tmp/api"]{value.provider = .chatCompletions;value.endpoint=endpoint;XCTAssertFalse(value.valid)}
        value.endpoint="http://127.0.0.1:12345/chat";XCTAssertTrue(value.valid);let before=value.credentialAccount;value.endpoint="http://127.0.0.1:12346/chat";XCTAssertNotEqual(value.credentialAccount,before)
        value.enabled=true;XCTAssertFalse(value.valid);value.model="fixture";XCTAssertTrue(value.valid)
    }
    private func form(_ request:URLRequest)->[String:[String]] {
        var result:[String:[String]]=[:]
        for pair in String(decoding:request.httpBody!,as:UTF8.self).split(separator:"&"){let parts=pair.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false);result[String(parts[0]).removingPercentEncoding!,default:[]].append(String(parts[1]).removingPercentEncoding!)};return result
    }
    func testProviderSignaturesAndUnicodeFormFieldsMatchIndependentVectors() throws {
        var settings=CaptureTranslationSettings()
        let credential=CaptureTranslationCredential(appID:"appid",secret:"secret")
        let youdao=try CaptureTranslationProtocol.request(texts:["Hello","世界"],settings:settings,credential:credential,salt:"salt",time:123456)
        let fields=form(youdao);XCTAssertEqual(fields["q"],["Hello","世界"]);XCTAssertEqual(fields["to"],["zh-CHS"]);XCTAssertEqual(fields["sign"],["6e1c5414c7f4057b21fc55327c4014b0227596214713ded34b17c4f05b1ca52f"])
        let unicodeRequest=try CaptureTranslationProtocol.request(texts:["😀😁😂😃😄😅😆😇😈😉😊😋😌😍😎😏😐😑😒😓😔😕😖😗"],settings:settings,credential:credential,salt:"salt",time:123456)
        XCTAssertEqual(form(unicodeRequest)["sign"],["0cf9e3d8d8988b1fd41b4e721c7941034c6fd42877d23e1590ad9eb31d479747"])
        settings.provider = .baidu
        let baidu=try CaptureTranslationProtocol.request(texts:["Hello","世界"],settings:settings,credential:credential,salt:"salt",time:123456)
        XCTAssertEqual(form(baidu)["q"],["Hello\n世界"]);XCTAssertEqual(form(baidu)["sign"],["ec8086de464be8a5e06e1441e1cef57e"])
        XCTAssertFalse(String(decoding:baidu.httpBody!,as:UTF8.self).contains("secret"))
    }
    func testResponseAlignmentErrorsAndModelTruncationAreRejected() throws {
        let source=["Hello","world"]
        let good=Data(#"{"errorCode":"0","translateResults":[{"query":"Hello","translation":"你好"},{"query":"world","translation":"世界"}]}"#.utf8)
        XCTAssertEqual(try CaptureTranslationProtocol.response(good,texts:source,provider:.youdao),["你好","世界"])
        let baidu=Data(#"{"trans_result":[{"src":"Hello","dst":"你好"},{"src":"world","dst":"世界"}]}"#.utf8)
        XCTAssertEqual(try CaptureTranslationProtocol.response(baidu,texts:source,provider:.baidu),["你好","世界"])
        XCTAssertThrowsError(try CaptureTranslationProtocol.response(good,texts:Array(source.reversed()),provider:.youdao))
        XCTAssertThrowsError(try CaptureTranslationProtocol.response(Data(#"{"errorCode":"202"}"#.utf8),texts:source,provider:.youdao))
        let bad=Data(#"{"choices":[{"finish_reason":"length","message":{"content":"[\"wrong\"]"}}]}"#.utf8)
        XCTAssertThrowsError(try CaptureTranslationProtocol.response(bad,texts:["one"],provider:.chatCompletions))
    }
    actor Requests {var values:[URLRequest]=[];func add(_ value:URLRequest){values.append(value)};func read()->[URLRequest]{values}}
    func testBatchingPreservesBlankLinesAndLongUTF8TextWithoutSendingImageData() async throws {
        let recorder=Requests();var settings=CaptureTranslationSettings();settings.enabled=true;settings.provider = .baidu
        let client=CaptureTranslationClient(send:{request in
            await recorder.add(request)
            let body=String(decoding:request.httpBody!,as:UTF8.self),q=body.split(separator:"&").first{ $0.hasPrefix("q=") }!.dropFirst(2).description.removingPercentEncoding!
            return try JSONSerialization.data(withJSONObject:["trans_result":q.components(separatedBy:"\n").map{["src":$0,"dst":"T"+$0]}])
        },pause:{})
        let source="Hello\n\n"+String(repeating:"界",count:2100)+"\nworld"
        let result=try await client.translate([source],settings:settings,credential:.init(appID:"id",secret:"secret"))
        XCTAssertTrue(result[0].hasPrefix("THello\n\nT"));XCTAssertTrue(result[0].hasSuffix("\nTworld"));let requests=await recorder.read();XCTAssertGreaterThan(requests.count,1);XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"Content-Type")!.contains("form-urlencoded")})
    }
    func testOverlayProducesAnIndependentImageAndRejectsImpossibleRegions() throws {
        let context=CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:400,height:200));let base=context.makeImage()!
        let result=try CaptureTranslationImage.overlay(base,regions:[.init(text:"source",bounds:CGRect(x:0.1,y:0.2,width:0.8,height:0.4))],translations:["译文 Test"])
        XCTAssertEqual(result.width,400);XCTAssertEqual(result.height,200);XCTAssertFalse(result === base)
        let original=NSBitmapImageRep(cgImage:base),output=NSBitmapImageRep(cgImage:result)
        XCTAssertEqual(original.colorAt(x:50,y:100)?.greenComponent,0);XCTAssertGreaterThan(output.colorAt(x:350,y:100)?.greenComponent ?? 0,0.9)
        XCTAssertThrowsError(try CaptureTranslationImage.overlay(base,regions:[.init(text:"source",bounds:CGRect(x:0,y:0,width:0.001,height:0.001))],translations:[String(repeating:"long",count:100)]))
    }
}

extension CaptureTranslationTests {
    func testLoopbackHTTPRedirectLimitAndCancellation() async throws {
        guard let endpoint=ProcessInfo.processInfo.environment["THERMO_TRANSLATION_TEST_ENDPOINT"],let url=URL(string:endpoint),url.host == "127.0.0.1",url.scheme == "http" else{throw XCTSkip("Set THERMO_TRANSLATION_TEST_ENDPOINT to the owned loopback fixture.")}
        var settings=CaptureTranslationSettings();settings.provider = .chatCompletions;settings.model="fixture";settings.enabled=true;settings.endpoint=endpoint
        let credential=CaptureTranslationCredential(secret:"fixture-only")
        let request=try CaptureTranslationProtocol.request(texts:["Hello"],settings:settings,credential:credential)
        let data=try await CaptureTranslationHTTP().send(request)
        XCTAssertEqual(try CaptureTranslationProtocol.response(data,texts:["Hello"],provider:.chatCompletions),["你好"])
        for (path,expected) in [("redirect",CaptureTranslationFailure.http(302)),("large",.tooLarge)] {
            settings.endpoint=url.deletingLastPathComponent().appendingPathComponent(path).absoluteString
            do{_=try await CaptureTranslationHTTP().send(CaptureTranslationProtocol.request(texts:["Hello"],settings:settings,credential:credential));XCTFail("expected transport rejection")}
            catch{XCTAssertEqual(error as? CaptureTranslationFailure,expected)}
        }
        settings.endpoint=url.deletingLastPathComponent().appendingPathComponent("slow").absoluteString
        let slow=try CaptureTranslationProtocol.request(texts:["Hello"],settings:settings,credential:credential)
        let task=Task{try await CaptureTranslationHTTP().send(slow)};try await Task.sleep(nanoseconds:100_000_000);task.cancel()
        do{_=try await task.value;XCTFail("cancelled request")}catch{XCTAssertTrue(error is CancellationError)}
    }
}
