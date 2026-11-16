import Foundation
import WAT

// thermo-wat2wasm <input.wat> <output.wasm>: builds the checked-in test fixtures.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: thermo-wat2wasm <input.wat> <output.wasm>\n".utf8)); exit(2)
}
do {
    let text = try String(contentsOfFile: arguments[1], encoding: .utf8)
    try Data(try wat2wasm(text)).write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
