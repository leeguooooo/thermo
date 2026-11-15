import AppKit
import XCTest
@testable import ThermoApp

@available(macOS 14,*)
@MainActor final class ScrollCaptureLifecycleTests:XCTestCase {
    private actor PhysicalRead {
        var continuation:CheckedContinuation<Void,Never>?
        var released=false
        func wait() async{if released{return};await withCheckedContinuation{continuation=$0}}
        func finish(){released=true;continuation?.resume();continuation=nil}
    }
    func testCancelledScrollRemainsBusyUntilActualFrameWorkReturns() async {
        let entered=expectation(description:"controlled physical frame read"),read=PhysicalRead();var calls=0
        let region=CaptureRegionSelector.Region(displayID:0,rect:CGRect(x:0,y:0,width:10,height:10),scale:1)
        let model=ScrollCaptureModel(region:region,captureLoop:{calls+=1;entered.fulfill();await read.wait()})
        model.start();await fulfillment(of:[entered],timeout:2)
        XCTAssertTrue(model.running)
        model.stop()
        XCTAssertTrue(model.running,"feature disable must still see the cancelled physical operation")
        model.start();XCTAssertEqual(calls,1,"old task must retain its slot")
        await read.finish();await model.finishStopping()
        XCTAssertFalse(model.running)
    }
}
