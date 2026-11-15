import Foundation
import XCTest
@testable import ThermoComposition

class ThermoCompositionTestCase:XCTestCase {
    override class func setUp(){
        super.setUp()
        let install={MainActor.assumeIsolated{ThermoComposition.install()}}
        if Thread.isMainThread{install()}else{DispatchQueue.main.sync(execute:install)}
    }
}
