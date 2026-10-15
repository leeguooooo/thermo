import Foundation
import Darwin

let mode = CommandLine.arguments[1]
let home = CommandLine.arguments[2]
let worker = CommandLine.arguments[3]
let count = Int(CommandLine.arguments[4])!
let fm = FileManager.default
if mode == "hold" {
    let directory = OperationJournal.url(home: home).deletingLastPathComponent().path
    let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0, flock(fd, LOCK_EX) == 0 else { exit(2) }
    try Data().write(to: URL(fileURLWithPath: home + "/ready-" + worker))
    while true { pause() }
} else {
    try Data().write(to: URL(fileURLWithPath: home + "/ready-" + worker))
    while !fm.fileExists(atPath: home + "/gate") { usleep(1000) }
    for index in 0..<count {
        OperationJournal.record(.init(id: "\(worker)-\(index)", feature: "qa", action: "append",
            items: [.init(target: String(repeating: "x", count: 2000), status: "done")]), home: home)
    }
}
