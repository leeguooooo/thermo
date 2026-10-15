@testable import CleanKit
import AgentCore
import Foundation
import XCTest

/// Upgrade a real small ZIP's central records to ZIP64, retaining every compressed byte.
func zip64Fixture(_ input: Data) throws -> Data {
    func read(_ data: Data, _ at: Int, _ size: Int) -> UInt64 {
        (0..<size).reduce(0) { $0 | UInt64(data[at + $1]) << (8 * $1) }
    }
    func put(_ data: inout Data, _ at: Int, _ value: UInt64, _ size: Int) {
        for i in 0..<size { data[at + i] = UInt8((value >> (8 * i)) & 255) }
    }
    func append(_ data: inout Data, _ value: UInt64, _ size: Int) {
        for i in 0..<size { data.append(UInt8((value >> (8 * i)) & 255)) }
    }
    let end = try XCTUnwrap(stride(from: input.count - 22, through: max(0, input.count - 65_557), by: -1).first { read(input, $0, 4) == 0x06054b50 })
    let count = Int(read(input, end + 10, 2)), offset = Int(read(input, end + 16, 4))
    var out = Data(input[..<offset]), cursor = offset
    for _ in 0..<count {
        XCTAssertEqual(read(input, cursor, 4), 0x02014b50)
        let name = Int(read(input, cursor + 28, 2)), extra = Int(read(input, cursor + 30, 2)), comment = Int(read(input, cursor + 32, 2))
        let compressed = read(input, cursor + 20, 4), expanded = read(input, cursor + 24, 4), local = read(input, cursor + 42, 4)
        var header = Data(input[cursor..<cursor + 46])
        put(&header, 6, 45, 2); put(&header, 20, 0xffffffff, 4); put(&header, 24, 0xffffffff, 4)
        put(&header, 42, 0xffffffff, 4); put(&header, 30, UInt64(extra + 28), 2)
        out.append(header); out.append(input[(cursor + 46)..<(cursor + 46 + name + extra)])
        append(&out, 1, 2); append(&out, 24, 2)
        append(&out, expanded, 8); append(&out, compressed, 8); append(&out, local, 8)
        out.append(input[(cursor + 46 + name + extra)..<(cursor + 46 + name + extra + comment)])
        cursor += 46 + name + extra + comment
    }
    let directorySize = out.count - offset, record = out.count
    append(&out, 0x06064b50, 4); append(&out, 44, 8); append(&out, 45, 2); append(&out, 45, 2)
    append(&out, 0, 4); append(&out, 0, 4); append(&out, UInt64(count), 8); append(&out, UInt64(count), 8)
    append(&out, UInt64(directorySize), 8); append(&out, UInt64(offset), 8)
    append(&out, 0x07064b50, 4); append(&out, 0, 4); append(&out, UInt64(record), 8); append(&out, 1, 4)
    append(&out, 0x06054b50, 4); append(&out, 0, 2); append(&out, 0, 2); append(&out, 0xffff, 2); append(&out, 0xffff, 2)
    append(&out, 0xffffffff, 4); append(&out, 0xffffffff, 4); append(&out, 0, 2)
    return out
}

final class NativeZip64ManifestTests: XCTestCase {
    func testMaliciousZIP64PointersAndCountsFailWithoutIntegerOverflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("file"), archive = root.appendingPathComponent("file.zip")
        try Data("fixture".utf8).write(to: source)
        let result = CommandRunner.run("/usr/bin/ditto", arguments: ["-c", "-k", source.path, archive.path], timeout: 10)
        XCTAssertEqual(result.status, 0)
        let valid = try zip64Fixture(Data(contentsOf: archive))
        try valid.write(to: archive)
        XCTAssertGreaterThan(try NativeZipManifest.validate(archive), 0)
        for offset in [valid.count - 34, valid.count - 98 + 32] {
            var bad = valid
            for i in 0..<8 { bad[offset + i] = 255 }
            try bad.write(to: archive)
            XCTAssertThrowsError(try NativeZipManifest.validate(archive))
        }
    }
}
