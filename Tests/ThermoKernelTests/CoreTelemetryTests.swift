import Combine
import Foundation
import NativeFeatureAPI
import SystemServicesAPI
import ThermoKit
import XCTest
@testable import ThermoKernel

@MainActor final class CoreTelemetryTests:XCTestCase {
    private final class Reader:@unchecked Sendable {
        let entered=XCTestExpectation(description:"sensor read held"),returned=XCTestExpectation(description:"old sensor returned"),fresh=XCTestExpectation(description:"fresh sensor read")
        let release=DispatchSemaphore(value:0)
        private let lock=NSLock();private var count=0
        var calls:Int{lock.lock();defer{lock.unlock()};return count}
        func read()->Snapshot {
            lock.lock();count+=1;let index=count;lock.unlock()
            if index==1{entered.fulfill();release.wait();returned.fulfill()}
            if index==2{fresh.fulfill()}
            return .init(timestamp:Date(timeIntervalSince1970:Double(index)),temperatures:[],fans:[],power:[],voltages:[],currents:[],battery:nil)
        }
    }
    private func counters()->MenuLiveSampler {
        let counter=MenuLiveSampler(readCPU:{nil},cpuPercent:{_,_ in nil})
        counter.readMemory={nil};counter.readNetwork={nil};return counter
    }
    func testPassiveLatestSubscriptionsAndOffAcquisitionNeverConstructWorker() throws {
        let name="CoreTelemetryCold."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        var made=0
        let service=CoreTelemetry(defaults:defaults,samplingAllowed:{true},makeWorker:{lifetime in
            made+=1;return TelemetryWorker(lifetime:lifetime,allowed:{true},defaults:defaults,readOverride:{_ in nil},counters:self.counters())
        })
        let menus=service.menuReadings.sink{_ in},values=service.readings.sink{_ in}
        XCTAssertNil(service.latest.snapshot);XCTAssertFalse(service.latest.sampling)
        service.preferencesDidChange();service.resetMenuBaselines();service.shutdown()
        XCTAssertThrowsError(try service.beginPerformanceSampling(available:{false}))
        XCTAssertEqual(made,0);withExtendedLifetime((menus,values)){}
    }
    func testRetirementWaitsForPhysicalReaderAndRejectsOldPublicationAndLease() async throws {
        let name="CoreTelemetryDrain."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!,reader=Reader()
        defer{reader.release.signal();defaults.removePersistentDomain(forName:name)}
        var made=0
        let service=CoreTelemetry(defaults:defaults,samplingAllowed:{true},makeWorker:{lifetime in
            made+=1;return TelemetryWorker(lifetime:lifetime,allowed:{true},defaults:defaults,readOverride:{_ in reader.read()},counters:self.counters())
        })
        var published:[Date]=[]
        let observation=service.readings.compactMap{$0.snapshot?.timestamp}.sink{published.append($0)}
        let old=try service.beginPerformanceSampling(available:{true})
        old.setDemand(.init(visible:true,surface:.sensors))
        await fulfillment(of:[reader.entered],timeout:3)
        old.beginStopping();var finished=false
        let drain=Task{await old.finishStopping();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        XCTAssertThrowsError(try service.beginPerformanceSampling(available:{true}))
        reader.release.signal();await fulfillment(of:[reader.returned],timeout:3);await drain.value
        XCTAssertFalse(service.latest.sampling);XCTAssertNil(service.latest.snapshot);XCTAssertTrue(published.isEmpty)
        let fresh=try service.beginPerformanceSampling(available:{true})
        fresh.setDemand(.init(visible:true,surface:.sensors))
        old.setDemand(.init(visible:true));old.refresh();old.resetMenuBaselines()
        await fulfillment(of:[reader.fresh],timeout:3)
        for _ in 0..<200 where service.latest.snapshot==nil{try? await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(made,2);XCTAssertFalse(published.contains(Date(timeIntervalSince1970:1)))
        XCTAssertNotNil(service.latest.snapshot)
        fresh.beginStopping();await fresh.finishStopping();withExtendedLifetime(observation){}
    }
}
