import AppKit
import XCTest
@testable import CaptureCore

final class CaptureTypedPinTests:XCTestCase {
    func testColorsParseCanonicalFormatsAndRejectMalformedInputs() throws {
        for source in ["#29B8DB","rgb(41, 184, 219)","41, 184, 219"] { XCTAssertEqual(CapturePinColor.parse(source)?.formatted(.hex),"#29B8DB") }
        XCTAssertEqual(CapturePinColor.parse("orange")?.formatted(.hex),"#FFA500")
        XCTAssertEqual(CapturePinColor.parse("RebeccaPurple")?.formatted(.hex),"#663399")
        XCTAssertEqual(CapturePinColor.parse("aliceblue")?.formatted(.hex),"#F0F8FF")
        XCTAssertEqual(CapturePinColor.parse("#abc")?.formatted(.hex),"#AABBCC")
        XCTAssertEqual(CapturePinColor.parse("#f008")?.formatted(.hex),"#FF000088")
        XCTAssertEqual(CapturePinColor.parse("rgb(100%,0%,0%)")?.formatted(.hex),"#FF0000")
        for source in ["hsl(120, 100%, 50%)","hsv(120,100%,100%)"] { XCTAssertEqual(CapturePinColor.parse(source)?.formatted(.hex),"#00FF00") }
        XCTAssertEqual(CapturePinColor.parse("rgba(1,2,3,50%)")?.alpha,0.5)
        for source in ["#12","#zzzzzz","rgb(256,0,0)","rgb(-1,2,3)","rgb(10%%,0,0)","rgba(0,0,0,nan)","thing(1,2,3)","hsl(inf,100%,50%)","random text","1,2,3,4"] { XCTAssertNil(CapturePinColor.parse(source),source) }
    }
    func testColorFormattingRoundTripsAndDoesNotDependOnLocale() throws {
        for color in [CapturePinColor(red:255,green:0,blue:0),.init(red:41,green:184,blue:219),.init(red:0,green:0,blue:0),.init(red:255,green:255,blue:255)] {
            for format in CapturePinColor.Format.allCases {
                let parsed=try XCTUnwrap(CapturePinColor.parse(color.formatted(format)))
                XCTAssertLessThanOrEqual(abs(parsed.red-color.red),2);XCTAssertLessThanOrEqual(abs(parsed.green-color.green),2);XCTAssertLessThanOrEqual(abs(parsed.blue-color.blue),2)
            }
        }
    }
    @MainActor func testRichTextPreservesFormattingButRemovesActiveLinksAndAttachments() throws {
        let original=NSAttributedString(string:"Bold 中文",attributes:[.font:NSFont.boldSystemFont(ofSize:22),.foregroundColor:NSColor.red,.link:URL(string:"https://example.invalid")!])
        let rtf=try original.data(from:NSRange(location:0,length:original.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        var value=CapturePinText(plain:original.string,rtf:rtf),rendered=try value.attributed()
        XCTAssertEqual(rendered.string,original.string);XCTAssertNil(rendered.attribute(.link,at:0,effectiveRange:nil))
        let font=try XCTUnwrap(rendered.attribute(.font,at:0,effectiveRange:nil) as? NSFont);XCTAssertEqual(font.pointSize,22)
        value.ignoreFormatting=true;value.fontSize=30;rendered=try value.attributed();XCTAssertEqual((rendered.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize,30)
        XCTAssertEqual(value.rtf,rtf);XCTAssertEqual(try CapturePinContent.text(value).previewImage().width > 0,true)
        XCTAssertThrowsError(try CapturePinText(plain:"x",rtf:Data("invalid".utf8)).attributed())
    }
    @MainActor func testTypedSnapshotsPersistSourceAndOldImagesRemainReadable() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("input.txt");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try Data("file payload".utf8).write(to:file)
        let store=CapturePinLibraryStore(root:root.appendingPathComponent("library"));var library=try store.load()
        let values:[CapturePinContent]=[.text(.init(plain:"Keep original 中文",html:"<b>Keep original 中文</b>")),.files([try CapturePinFile(url:file)]),.color(.init(red:41,green:184,blue:219))]
        var docs:[UUID:CaptureDocument]=[:],contents:[UUID:CapturePinContent]=[:]
        for value in values { var pin=CaptureSavedPin(groupID:library.currentGroupID);pin.contentKind=value.kind;library.pins.append(pin);docs[pin.id]=CaptureDocument(image:try value.previewImage());contents[pin.id]=value }
        try store.save(library,documents:docs,contents:contents)
        let fresh=CapturePinLibraryStore(root:store.root),loaded=try fresh.load()
        for (pin,value) in zip(loaded.pins,values) { XCTAssertEqual(try fresh.snapshot(for:pin).content,value) }
        let pin=loaded.pins[0],contentFile=store.root.appendingPathComponent("snapshots/"+pin.snapshotID.uuidString+"/content.json")
        try FileManager.default.removeItem(at:contentFile);XCTAssertThrowsError(try fresh.snapshot(for:pin))
        var legacy=pin;legacy.contentKind=nil;XCTAssertNil(try fresh.snapshot(for:legacy).content)
    }
    func testMissingFilesRetainPathAndRejectRemoteURLs() throws {
        let file=try CapturePinFile(url:URL(fileURLWithPath:"/tmp/nonexistent-"+UUID().uuidString));XCTAssertEqual(try file.resolved().path,file.path)
        XCTAssertThrowsError(try CapturePinFile(url:URL(string:"https://example.invalid/file")!))
        XCTAssertFalse(CapturePinContent.files([]).valid)
        XCTAssertFalse(CapturePinContent.text(.init(plain:String(repeating:"x",count:1024*1024+1))).valid)
    }
}
