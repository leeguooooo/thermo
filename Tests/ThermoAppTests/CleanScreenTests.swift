import XCTest
import Combine
@testable import ThermoApp

final class CleanScreenTests: XCTestCase {
    func testTimedModesUseMonotonicElapsedTimeAndManualDoesNotExpire() {
        for duration in CleanScreenDuration.allCases {
            let s=CleanScreenSession(started:100,duration:duration)
            if let seconds=duration.seconds {
                XCTAssertNil(s.finish(100+seconds-0.01));XCTAssertEqual(s.finish(100+seconds),.duration)
                XCTAssertEqual(s.remaining(0),seconds)
            } else { XCTAssertNil(s.finish(1_000_000));XCTAssertNil(s.remaining(1_000_000)) }
        }
    }
    func testEscapeRequiresContinuousUnmodifiedHoldAndIgnoresRepeatStarts() {
        var s=CleanScreenSession(started:0,duration:.manual)
        s.key(53,down:true,repeated:true,modified:false,now:1);XCTAssertNil(s.finish(100))
        s.key(53,down:true,repeated:false,modified:false,now:100)
        s.key(53,down:true,repeated:true,modified:false,now:102)
        XCTAssertNil(s.finish(102.99));XCTAssertEqual(s.finish(103),.escape)
        s.key(53,down:false,repeated:false,modified:false,now:103);XCTAssertNil(s.finish(104))
        s.key(53,down:true,repeated:false,modified:true,now:104);XCTAssertNil(s.finish(200))
    }
    func testModifierTransitionRequiresANewEscapePress() {
        var s=CleanScreenSession(started:0,duration:.manual)
        s.key(53,down:true,repeated:false,modified:false,now:1);s.modifiersChanged()
        s.key(53,down:true,repeated:true,modified:false,now:3);XCTAssertNil(s.finish(10))
        s.key(53,down:true,repeated:false,modified:false,now:10);XCTAssertEqual(s.finish(13),.escape)
    }
    func testPointerReleaseResetsHoldAndProgressIsBounded() {
        var s=CleanScreenSession(started:0,duration:.manual)
        s.pointer(true,now:10);s.pointer(true,now:11)
        XCTAssertEqual(s.holdProgress(11.5),0.5);XCTAssertEqual(s.holdProgress(5),0)
        s.pointer(false,now:12);XCTAssertEqual(s.holdProgress(20),0);XCTAssertNil(s.finish(20))
        s.pointer(true,now:20);XCTAssertEqual(s.finish(23),.pointer);XCTAssertEqual(s.holdProgress(100),1)
    }
    func testDisplayOrderingAndUnrelatedNotificationsDoNotChangeCoverage() throws {
        let a=CleanScreenDisplay(id:1,frame:.init(x:0,y:0,width:1800,height:1200),scale:2)
        let b=CleanScreenDisplay(id:2,frame:.init(x:-1920,y:0,width:1920,height:1080),scale:1)
        XCTAssertEqual(CleanScreenDisplay.normalized([a,b]),CleanScreenDisplay.normalized([b,a]))
        for changed in [CleanScreenDisplay(id:3,frame:b.frame,scale:1),CleanScreenDisplay(id:2,frame:a.frame,scale:1),CleanScreenDisplay(id:2,frame:b.frame,scale:2)] {
            XCTAssertNotEqual(CleanScreenDisplay.normalized([a,b]),CleanScreenDisplay.normalized([a,changed]))
        }
        XCTAssertNotEqual(CleanScreenDisplay.normalized([a,b]),CleanScreenDisplay.normalized([a]))
    }
    func testUnknownOrInvalidDisplayCoverageCannotBeAccepted() {
        XCTAssertNil(CleanScreenDisplay.normalized([]))
        let valid=CleanScreenDisplay(id:1,frame:.init(x:0,y:0,width:1,height:1),scale:1)
        XCTAssertNil(CleanScreenDisplay.normalized([valid,valid]))
        for display in [CleanScreenDisplay(id:0,frame:valid.frame,scale:1),CleanScreenDisplay(id:1,frame:.zero,scale:1),CleanScreenDisplay(id:1,frame:valid.frame,scale:.nan)] {
            XCTAssertNil(CleanScreenDisplay.normalized([display]))
        }
    }
    @MainActor final class Driver: CleanScreenDriver {
        var hasAccessibility=true, fails=false
        var starts=0, ends=0
        enum Failure: Error { case fixture }
        func begin(_ model: CleanScreenModel) throws { starts+=1;if fails { throw Failure.fixture } }
        func end() { ends+=1 }
    }
    @MainActor func testDeniedPermissionNeverBeginsOrPresentsAnOverlay() {
        let driver=Driver();driver.hasAccessibility=false
        let model=CleanScreenModel(driver:driver);model.start(.oneMinute)
        XCTAssertFalse(model.active);XCTAssertNotNil(model.issue);XCTAssertEqual(driver.starts,0);XCTAssertEqual(driver.ends,0)
    }
    @MainActor func testPartialStartFailureUnwindsAndCanRetry() {
        let driver=Driver();driver.fails=true
        let model=CleanScreenModel(driver:driver);model.start(.oneMinute)
        XCTAssertFalse(model.active);XCTAssertNotNil(model.issue);XCTAssertNil(model.interruption);XCTAssertEqual(driver.ends,1)
        driver.fails=false;model.start(.twoMinutes)
        XCTAssertTrue(model.active);XCTAssertNil(model.issue);XCTAssertEqual(driver.starts,2)
        model.stop();XCTAssertEqual(driver.ends,2)
    }
    @MainActor func testDurationStopsOnceAndDuplicateStartDoesNotReplaceActiveSession() {
        let driver=Driver();var time=100.0
        let model=CleanScreenModel(driver:driver,clock:{time});model.start(.oneMinute);model.start(.manual)
        XCTAssertEqual(driver.starts,1);XCTAssertEqual(model.session?.duration,.oneMinute)
        time=160;model.tick();model.tick();model.stop()
        XCTAssertFalse(model.active);XCTAssertEqual(model.finished,.duration);XCTAssertEqual(driver.ends,1)
    }
    @MainActor func testInterruptionImmediatelyEndsAndLateInputIsIgnored() {
        let driver=Driver();let model=CleanScreenModel(driver:driver)
        model.start(.manual);model.stop(interruption:.tapDisabled)
        model.key(53,down:true,repeated:false,modified:false);model.holdExit(true);model.tick();model.stop(interruption:.tapDisabled)
        XCTAssertFalse(model.active);XCTAssertNotNil(model.issue);XCTAssertEqual(model.interruption,.tapDisabled);XCTAssertEqual(driver.ends,1)
    }
    @MainActor func testFreshSessionDoesNotInheritAnEarlierExitHold() {
        let driver=Driver();var time=1.0
        let model=CleanScreenModel(driver:driver,clock:{time});model.start(.manual);model.holdExit(true)
        time=4;model.tick();XCTAssertFalse(model.active)
        model.start(.manual);time=100;model.tick();XCTAssertTrue(model.active)
        model.key(53,down:true,repeated:false,modified:false);time=103;model.tick();XCTAssertFalse(model.active)
        XCTAssertEqual(driver.ends,2)
    }
    @MainActor func testOrdinaryCleaningInputDoesNotContinuouslyRepublishTheOverlay() {
        let model=CleanScreenModel(driver:Driver())
        model.start(.manual)
        var changes=0
        let subscription=model.$session.dropFirst().sink { _ in changes+=1 }
        for _ in 0..<1000 {
            model.key(0,down:true,repeated:false,modified:false)
            model.modifiersChanged()
        }
        XCTAssertEqual(changes,0)
        model.key(53,down:true,repeated:false,modified:false)
        XCTAssertEqual(changes,1)
        subscription.cancel();model.stop()
    }
}
