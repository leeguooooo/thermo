import AppKit
import XCTest
@testable import CaptureCore

final class CaptureLaTeXTests:XCTestCase {
    func testDelimiterDetectionPreservesOriginalSourceAndDisplayMode() {
        for source in ["$$\\frac{1}{2}$$","\\[a^2+b^2\\]","\\frac{1}{2}","\\begin{aligned}a&=b\\end{aligned}"] {
            let formula=CaptureLaTeX.detect(source);XCTAssertEqual(formula?.source,source);XCTAssertEqual(formula?.display,true)
        }
        XCTAssertEqual(CaptureLaTeX.detect("$\\text{\\$5}$")?.display,false)
        XCTAssertEqual(CaptureLaTeX.detect("\\theta")?.expression,"\\theta")
        XCTAssertEqual(CaptureLaTeX.detect("$x^2$")?.expression,"x^2");XCTAssertEqual(CaptureLaTeX.detect("\\(x\\)")?.display,false)
        for source in ["ordinary text","$100 and $20","$$","\\Users\\folder","\\internal\\directory"] { XCTAssertNil(CaptureLaTeX.detect(source),source) }
    }
    @MainActor func testFractionsMatricesAndChemistryProduceRealSVGAndMathML() throws {
        for (source,semantic) in [("\\frac{a^2+b^2}{\\sqrt{x}}","mfrac"),("\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}","mtable"),("\\ce{H2O}","msub")] {
            let value=try CaptureLaTeX(source:source).render()
            XCTAssertTrue(value.svg.hasPrefix("<svg "));XCTAssertTrue(value.svg.contains("<path"));XCTAssertFalse(value.svg.contains("foreignObject"));XCTAssertTrue(value.mathml.contains("<"+semantic))
            XCTAssertEqual(value.image.width,Int(value.logicalSize.width)*2);XCTAssertGreaterThan(ink(value.image).count,20)
        }
        for source in ["\\cancel{x}","\\bbox[5px,border:2px solid red]{x+y}","\\enclose{circle}{x}","\\begin{cases}x&x>0\\\\0&x=0\\end{cases}","\\qty(\\frac{a}{b})","\\begin{aligned}a&=b+c\\\\d&=e\\end{aligned}"] {
            let value=try CaptureLaTeX(source:source).render();XCTAssertGreaterThan(ink(value.image).count,20);XCTAssertFalse(value.svg.contains("data-latex"))
        }
    }
    @MainActor func testMacrosAreBoundedAndDoNotLeakBetweenFormulas() throws {
        XCTAssertNoThrow(try CaptureLaTeX(source:"\\newcommand{\\R}{\\mathbb{R}}\\R").render())
        XCTAssertThrowsError(try CaptureLaTeX(source:"\\R").render())
        for source in ["\\def\\loop{\\loop}\\loop","\\href{https://example.invalid}{x}","\\require{html}","\\htmlClass{unsafe}{x}","\\notACommand{x}","\\frac{"] { XCTAssertThrowsError(try CaptureLaTeX(source:source).render(),source) }
        XCTAssertGreaterThan(try CaptureLaTeX(source:"x+1").render().image.width,0)
    }
    @MainActor func testColorTransparencyAndBackgroundAffectNativePixels() throws {
        var formula=CaptureLaTeX(source:"x^2+y^2");formula.foreground="#FF0000"
        let transparent=try formula.render(),pixels=ink(transparent.image)
        XCTAssertTrue(pixels.contains { $0.redComponent > 0.8 && $0.greenComponent < 0.2 })
        XCTAssertLessThan(NSBitmapImageRep(cgImage:transparent.image).colorAt(x:0,y:0)!.alphaComponent,0.01)
        formula.transparentBackground=false;formula.background="#00FF00"
        let solid=try formula.render(),corner=try XCTUnwrap(NSBitmapImageRep(cgImage:solid.image).colorAt(x:0,y:0))
        XCTAssertGreaterThan(corner.alphaComponent,0.99);XCTAssertGreaterThan(corner.greenComponent,0.9)
        formula.fontSize=48;XCTAssertGreaterThan(try formula.render().logicalSize.width,solid.logicalSize.width)
    }
    @MainActor func testOversizedAndInvalidFormulaFailsBeforeExport() throws {
        XCTAssertFalse(CaptureLaTeX(source:String(repeating:"x",count:16385)).valid)
        XCTAssertThrowsError(try CaptureLaTeX(source:"\\rule{100000em}{100em}").render())
        var formula=CaptureLaTeX(source:"x");formula.foreground="url(http://example.invalid)";XCTAssertThrowsError(try formula.render())
    }
    @MainActor func testFormulaSnapshotPreservesSourceAndStyleForReopen() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let store=CapturePinLibraryStore(root:root);var library=try store.load(),formula=CaptureLaTeX(source:"$$\\int_0^1 x^2 dx$$");formula.fontSize=40;formula.foreground="#2244AA"
        var pin=CaptureSavedPin(groupID:library.currentGroupID);pin.contentKind="latex";library.pins=[pin]
        let content=CapturePinContent.latex(formula),doc=CaptureDocument(image:try content.previewImage())
        try store.save(library,documents:[pin.id:doc],contents:[pin.id:content])
        let fresh=CapturePinLibraryStore(root:root),loaded=try fresh.load(),snapshot=try fresh.snapshot(for:loaded.pins[0]);XCTAssertEqual(snapshot.content,content)
        XCTAssertEqual(try snapshot.document.data(),try doc.data())
    }
    private func ink(_ image:CGImage) -> [NSColor] {
        let rep=NSBitmapImageRep(cgImage:image);var result:[NSColor]=[]
        for y in stride(from:0,to:image.height,by:2) { for x in stride(from:0,to:image.width,by:2) { if let color=rep.colorAt(x:x,y:y),color.alphaComponent > 0.2 { result.append(color.usingColorSpace(.deviceRGB)!) } } };return result
    }
}
