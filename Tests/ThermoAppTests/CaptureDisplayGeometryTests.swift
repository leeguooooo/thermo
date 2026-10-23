import AppKit
import XCTest
@testable import ThermoApp

@MainActor final class CaptureDisplayGeometryTests:XCTestCase {
    func testRetinaAndExternalDisplayUseTheirOwnScaleAndEvenOutputDimensions() throws {
        let retina=CaptureRegionSelector.Region(displayID:1,rect:CGRect(x:100,y:50,width:901,height:501),scale:2,selectedDisplaySize:CGSize(width:1800,height:1169))
        try retina.validate(displaySize:CGSize(width:1800,height:1169),scale:2)
        XCTAssertEqual(try retina.recordingPixelSize().width,1802);XCTAssertEqual(try retina.recordingPixelSize().height,1002)
        let external=CaptureRegionSelector.Region(displayID:3,rect:CGRect(x:100,y:50,width:901,height:501),scale:1,selectedDisplaySize:CGSize(width:1920,height:1080))
        try external.validate(displaySize:CGSize(width:1920,height:1080),scale:1)
        XCTAssertEqual(try external.recordingPixelSize().width,900);XCTAssertEqual(try external.recordingPixelSize().height,500)
    }
    func testResolutionOrScaleChangeRejectsOldSelectionEvenWhenItStillFits() throws {
        let region=CaptureRegionSelector.Region(displayID:3,rect:CGRect(x:100,y:50,width:600,height:400),scale:1,selectedDisplaySize:CGSize(width:1920,height:1080))
        XCTAssertThrowsError(try region.validate(displaySize:CGSize(width:2560,height:1440),scale:1))
        XCTAssertThrowsError(try region.validate(displaySize:CGSize(width:1920,height:1080),scale:2))
    }
    func testInvalidRegionsCannotReachPixelIntegerConversion() throws {
        for rect in [CGRect(x:-1,y:0,width:100,height:100),CGRect(x:1900,y:0,width:100,height:100),CGRect(x:0,y:0,width:31,height:100),CGRect(x:0,y:0,width:CGFloat.infinity,height:100)] {
            let r=CaptureRegionSelector.Region(displayID:1,rect:rect,scale:1)
            XCTAssertThrowsError(try r.validate(displaySize:CGSize(width:1920,height:1080),scale:1))
        }
        for scale in [CGFloat.nan,CGFloat.infinity,0,-1] {XCTAssertThrowsError(try CaptureRegionSelector.Region(displayID:1,rect:CGRect(x:0,y:0,width:100,height:100),scale:scale).recordingPixelSize())}
    }
    func testLargeRetinaDisplayIsBoundedAndRemainsEven() throws {
        let region=CaptureRegionSelector.Region(displayID:1,rect:CGRect(x:0,y:0,width:4000,height:2250),scale:2)
        let size=try region.recordingPixelSize();XCTAssertEqual(size.width,4096);XCTAssertEqual(size.height,2304)
    }
    func testPointerMappingUsesSelectedDisplayOriginAndTopLeftPointsWithoutRetinaMultiplication() {
        let region=CaptureRegionSelector.Region(displayID:3,rect:CGRect(x:100,y:200,width:800,height:400),scale:2)
        for origin in [CGPoint(x:-1920,y:0),CGPoint(x:1800,y:-1080),CGPoint(x:0,y:1169)] {
            let frame=CGRect(origin:origin,size:CGSize(width:1920,height:1080))
            XCTAssertEqual(region.normalizedPointer(CGPoint(x:origin.x+300,y:origin.y+300),displayFrame:frame),CGPoint(x:0.25,y:0.75))
            XCTAssertNil(region.normalizedPointer(CGPoint(x:origin.x+20,y:origin.y+20),displayFrame:frame))
        }
    }
    func testDisconnectedDisplayFailsBeforePermissionOrDraftCreation() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("recording-disconnected-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let model=CaptureRecordingModel(region:.init(displayID:UInt32.max,rect:CGRect(x:0,y:0,width:800,height:600),scale:1),store:.init(root:root))
        model.delay=0;model.start()
        for _ in 0..<100 where model.phase == .starting {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(model.phase,.failed);XCTAssertFalse(model.active);XCTAssertNil(model.currentDraft);XCTAssertNil(model.source);XCTAssertNotNil(model.issue)
        XCTAssertTrue(try model.store.list().isEmpty)
    }
    func testDisplayChangeDuringCountdownCancelsAndRemovesObserverWithoutCreatingDraft() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("recording-countdown-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var valid=true,checks=0
        let model=CaptureRecordingModel(region:.init(displayID:UInt32.max,rect:CGRect(x:0,y:0,width:800,height:600),scale:1),store:.init(root:root),validateDisplay:{_ in checks+=1;if !valid {throw CaptureDisplayFailure.changed}})
        model.delay=5;model.start()
        for _ in 0..<100 where checks == 0 {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(checks,1);valid=false
        NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
        for _ in 0..<100 where model.phase == .starting {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(model.phase,.ready);XCTAssertNotNil(model.issue);XCTAssertNil(model.currentDraft);XCTAssertTrue(try model.store.list().isEmpty)
        let finishedChecks=checks;NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil);XCTAssertEqual(checks,finishedChecks)
    }
    func testPostCountdownValidationRejectsStaleSelectionBeforeScreenPermissionRequest() async throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("recording-after-countdown-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var checks=0
        let model=CaptureRecordingModel(region:.init(displayID:UInt32.max,rect:CGRect(x:0,y:0,width:800,height:600),scale:1),store:.init(root:root),validateDisplay:{_ in checks+=1;if checks>=2 {throw CaptureDisplayFailure.changed}})
        model.delay=0;model.start()
        for _ in 0..<100 where model.phase == .starting {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(checks,2);XCTAssertEqual(model.phase,.failed);XCTAssertNil(model.currentDraft);XCTAssertTrue(try model.store.list().isEmpty)
    }
}
