import XCTest
@testable import CaptureScriptCore

final class CaptureScriptRunnerTests:XCTestCase {
    private func worker() throws -> URL {
        var folder=Bundle(for:Self.self).bundleURL
        for _ in 0..<8 {
            let candidate=folder.appendingPathComponent("thermo-capture-script")
            if FileManager.default.isExecutableFile(atPath:candidate.path){return candidate};folder.deleteLastPathComponent()
        };throw CaptureScriptFailure.unavailable
    }
    actor Calls {var values:[String]=[];func add(_ value:String){values.append(value)};func read()->[String]{values}}
    func testActualJavaScriptConditionsLoopsRPCValuesAndConsole() async throws {
        let calls=Calls()
        let result=try await CaptureScriptRunner.run(source:"let total=0;for(let i=0;i<3;i++){if(thermo.perform('pin')===true)total+=i;}console.log('total',total);return {total,items:['ok',null]};",worker:worker()) {action in await calls.add(action);return .bool(true)}
        let received=await calls.read();XCTAssertEqual(received,["pin","pin","pin"]);XCTAssertEqual(result.logs,["total 3"])
        XCTAssertEqual(result.value,.object(["total":.number(3),"items":.array([.string("ok"),.null])]))
    }
    func testNullUndefinedAndFalseResultsRemainValidProtocolValues() async throws {
        for (source,expected) in [("return null;",CaptureScriptValue.null),("console.log('no return');",.null),("return false;",.bool(false))] {
            let result=try await CaptureScriptRunner.run(source:source,worker:worker()){_ in .null};XCTAssertEqual(result.value,expected)
        }
    }
    func testWorkerHasNoNodeBrowserOrRawBridgeGlobals() async throws {
        let result=try await CaptureScriptRunner.run(source:"return [typeof require,typeof process,typeof fetch,typeof window,typeof __thermoCall,typeof __thermoLog];",worker:worker()){_ in .null}
        XCTAssertEqual(result.value,.array(Array(repeating:.string("undefined"),count:6)))
    }
    func testActionErrorsCanBeCaughtAndUncaughtExceptionsStopLaterCalls() async throws {
        let calls=Calls()
        let result=try await CaptureScriptRunner.run(source:"try{thermo.perform('fail')}catch(e){console.log(e.message)};return thermo.perform('after');",worker:worker()){action in
            if action == "fail"{throw CaptureScriptFailure.execution("fixture error")};await calls.add(action);return .string("done")
        }
        XCTAssertEqual(result.value,.string("done"));XCTAssertEqual(result.logs,["fixture error"])
        do {_=try await CaptureScriptRunner.run(source:"throw new Error('stop here');thermo.perform('never');",worker:worker()){_ in XCTFail("after exception");return .null};XCTFail("expected exception")}
        catch {XCTAssertTrue(error.localizedDescription.contains("stop here"))}
    }
    func testInfiniteLoopTimeoutDoesNotBlockNextRun() async throws {
        do {_=try await CaptureScriptRunner.run(source:"while(true){}",worker:worker(),timeout:0.2){_ in .null};XCTFail("expected timeout")}
        catch {XCTAssertEqual(error as? CaptureScriptFailure,.timedOut)}
        let result=try await CaptureScriptRunner.run(source:"return 42;",worker:worker()){_ in .null};XCTAssertEqual(result.value,.number(42))
    }
    func testKernelCPUTimeLimitStopsComputationBeforeWallTimeout() async throws {
        do {_=try await CaptureScriptRunner.run(source:"while(true){}",worker:worker(),timeout:40){_ in .null};XCTFail("expected CPU termination")}
        catch {XCTAssertEqual(error as? CaptureScriptFailure,.workerStopped)}
    }
    func testCancellationInterruptsPendingNativeActionAndReapsWorker() async throws {
        let worker=try worker(),started=expectation(description:"native action started")
        let task=Task {try await CaptureScriptRunner.run(source:"thermo.perform('wait');return 'late';",worker:worker){_ in
            started.fulfill();try await Task.sleep(nanoseconds:10_000_000_000);return .null
        }}
        await fulfillment(of:[started],timeout:3);task.cancel()
        do {_=try await task.value;XCTFail("expected cancellation")}catch{XCTAssertEqual(error as? CaptureScriptFailure,.cancelled)}
    }
    func testTimeoutReturnsEvenIfNativeWorkDoesNotCooperateWithCancellation() async throws {
        let start=Date()
        do {_=try await CaptureScriptRunner.run(source:"thermo.perform('slow');",worker:worker(),timeout:0.1){_ in
            try await Task.detached {try await Task.sleep(nanoseconds:1_000_000_000)}.value;return .null
        };XCTFail("expected timeout")}catch{XCTAssertEqual(error as? CaptureScriptFailure,.timedOut)}
        XCTAssertLessThan(Date().timeIntervalSince(start),0.8)
    }
    func testMemoryWatchdogAndOutputBoundsTerminateWorker() async throws {
        do {_=try await CaptureScriptRunner.run(source:"const a=[];for(let i=0;i<100000;i++){a.push(new Array(32768).fill(i));thermo.perform('tick');}",worker:worker(),timeout:5,memoryBytes:96*1024*1024){_ in try await Task.sleep(nanoseconds:1_000_000);return .null};XCTFail("expected memory limit")}
        catch {XCTAssertEqual(error as? CaptureScriptFailure,.memoryLimit)}
        do {_=try await CaptureScriptRunner.run(source:"for(let i=0;i<300;i++)console.log('bounded log');",worker:worker()){_ in .null};XCTFail("expected log limit")}
        catch {XCTAssertEqual(error as? CaptureScriptFailure,.protocolError)}
    }
    func testMissingWorkerInvalidSourceSyntaxAndPromiseResultsFailClearly() async throws {
        for source in ["",String(repeating:"a",count:16385)] {
            do {_=try await CaptureScriptRunner.run(source:source,worker:worker()){_ in .null};XCTFail("invalid source")}
            catch{XCTAssertEqual(error as? CaptureScriptFailure,.invalidSource)}
        }
        for source in ["function {", "return Promise.resolve(1);"] {
            do {_=try await CaptureScriptRunner.run(source:source,worker:worker()){_ in .null};XCTFail("invalid script")}
            catch{XCTAssertNotNil(error as? CaptureScriptFailure)}
        }
        do {_=try await CaptureScriptRunner.run(source:"return 1;",worker:URL(fileURLWithPath:"/nonexistent/thermo-script")){_ in .null};XCTFail("missing worker")}
        catch{XCTAssertEqual(error as? CaptureScriptFailure,.unavailable)}
    }
}
