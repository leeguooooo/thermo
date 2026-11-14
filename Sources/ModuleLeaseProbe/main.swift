import Darwin
import Foundation
import ModuleKit

do {
    guard CommandLine.arguments.count == 4 else { throw ModuleCommandLease.Failure.unsafeLocation }
    let home=CommandLine.arguments[1],feature=CommandLine.arguments[2],mode=CommandLine.arguments[3]
    guard ["blocking","watch","stop"].contains(mode) else {throw ModuleCommandLease.Failure.unsafeLocation}
    if mode=="stop" {
        let stop=try ModuleCommandLease.quiesce(feature:feature,home:home)
        let deadline=Date().addingTimeInterval(15)
        while !stop.readersFinished && Date()<deadline {usleep(10_000)}
        guard stop.readersFinished else {throw ModuleCommandLease.Failure.busy(feature)}
        stop.release();exit(0)
    }
    let lease=try ModuleCommandLease.begin(feature:feature,interruptible:mode=="watch",home:home,enabled:{true})
    let root=URL(fileURLWithPath:home)
    try Data("ready".utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)
    let deadline=Date().addingTimeInterval(15)
    while Date()<deadline && !FileManager.default.fileExists(atPath:root.appendingPathComponent("done").path) {
        if mode=="watch" && lease.stopRequested {break}
        usleep(10_000)
    }
    withExtendedLifetime(lease) {}
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)
}
