// Read-only observer. It never creates, renews or releases a power assertion.
import Foundation
import IOKit.pwr_mgt
import Darwin

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fputs("Expected one positive target PID\n", stderr); exit(2)
}
var raw: Unmanaged<CFDictionary>?
guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
      let inventory = raw?.takeRetainedValue() as NSDictionary? else {
    fputs("Assertion inventory unavailable\n", stderr); exit(3)
}
let rows: [NSDictionary]
if let value = inventory[NSNumber(value: pid)] {
    guard let values = value as? [NSDictionary] else { fputs("Unknown target inventory shape\n", stderr); exit(3) }
    rows = values
} else { rows = [] }
var owned: [[String: Any]] = []
for row in rows {
    guard let name = row[kIOPMAssertionNameKey] as? String else { fputs("Assertion name unavailable\n", stderr); exit(3) }
    guard name.hasPrefix("Thermo keep-awake ") else { continue }
    guard let kind = row[kIOPMAssertionTypeKey] as? String, let level = row[kIOPMAssertionLevelKey] as? NSNumber else {
        fputs("Unknown owned assertion shape\n", stderr); exit(3)
    }
    var value: [String: Any] = ["name": name, "type": kind, "level": level.intValue, "active": level.intValue == Int(kIOPMAssertionLevelOn)]
    if let timeout = row[kIOPMAssertionTimeoutKey] as? NSNumber { value["timeoutSeconds"] = timeout.doubleValue }
    owned.append(value)
}
let result: [String: Any] = ["targetPID": pid, "inventoryAvailable": true, "owned": owned,
    "activeOwnedCount": owned.filter { ($0["level"] as? Int) == Int(kIOPMAssertionLevelOn) }.count,
    "observerCreatesAssertions": false]
do {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch { fputs("Cannot encode observation\n", stderr); exit(3) }
