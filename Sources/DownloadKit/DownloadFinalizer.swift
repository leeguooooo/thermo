import CryptoKit
import Foundation

enum DownloadFinalizer {
    private static let bufferSize = 1 << 20

    /// Merges the selected chain into a temp file beside the destination (same volume, so the
    /// publish is a real rename), verifies its size, then publishes under a free name.
    /// Part files are only read, so any failure leaves them available for another try.
    static func finalize(segments: [Segment], size: Int64, destination: URL, partURL: (Int) -> URL) throws -> URL {
        let chain = try SegmentChain.select(segments: segments, size: size).get()
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temp = tempURL(beside: destination)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard manager.createFile(atPath: temp.path, contents: nil) else {
                throw DownloadError.io("cannot create \(temp.path)")
            }
            defer { try? manager.removeItem(at: temp) }
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            for link in chain {
                let segment = segments.first { $0.id == link.segmentID }
                // A link that skips a prefix or stops short covers different bytes than the hash.
                let whole = link.skip == 0 && link.length == segment?.covered
                let expected = whole ? segment?.sha256 : nil
                try copy(link, from: partURL(link.segmentID), to: output, expectedHash: expected)
            }
            try output.synchronize()
            let actual = (try manager.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard actual == size else {
                throw DownloadError.sizeMismatch(expected: size, actual: actual)
            }
            return try publish(temp, to: destination)
        } catch let error as DownloadError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadError.io(error.localizedDescription)
        }
    }

    private static func copy(_ link: ChainLink, from part: URL, to output: FileHandle, expectedHash: String?) throws {
        let input = try FileHandle(forReadingFrom: part)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(link.skip))
        var left = link.length
        var digest = SHA256()
        while left > 0 {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Int(min(left, Int64(bufferSize)))), !data.isEmpty else { return }
            try output.write(contentsOf: data)
            if expectedHash != nil { digest.update(data: data) }
            left -= Int64(data.count)
        }
        if let expectedHash, PartHash.hex(digest.finalize()) != expectedHash {
            throw DownloadError.corruptPart(segment: link.segmentID)
        }
    }

    /// A fixed length, because a long name plus a suffix can pass the volume's 255-byte limit.
    static func tempURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
    }

    /// `RENAME_EXCL` makes "does it exist" and "move" one step, so nothing can be overwritten.
    /// Files saved through this engine are quarantined before they get their visible name.
    /// P2P output never comes through here: Gopeed writes it, and `DownloadQuarantine` is called on it directly.
    static func publish(
        _ source: URL, to destination: URL,
        rename: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
    ) throws -> URL {
        DownloadQuarantine.mark(source)
        for index in 0..<10_000 {
            let candidate = uniqueName(for: destination, index: index)
            if rename(source.path, candidate.path) == 0 { return candidate }
            switch errno {
            case EEXIST:
                continue
            case EXDEV:
                // A staged copy on the target volume keeps the final name from ever showing a partial file.
                let staged = tempURL(beside: destination)
                defer { try? FileManager.default.removeItem(at: staged) }
                guard copyfile(source.path, staged.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)) == 0 else {
                    throw DownloadError.io(String(cString: strerror(errno)))
                }
                let published = try publish(staged, to: destination)
                unlink(source.path)
                return published
            case ENOTSUP, EINVAL:
                // Some network volumes lack RENAME_EXCL; a hard link is exclusive too.
                if link(source.path, candidate.path) == 0 {
                    unlink(source.path)
                    return candidate
                }
                if errno == EEXIST { continue }
                throw DownloadError.io(String(cString: strerror(errno)))
            default:
                throw DownloadError.io(String(cString: strerror(errno)))
            }
        }
        throw DownloadError.io("no free name for \(destination.lastPathComponent)")
    }

    static func uniqueName(for destination: URL, index: Int) -> URL {
        guard index > 0 else { return destination }
        let base = destination.deletingPathExtension().lastPathComponent
        let suffix = destination.pathExtension
        let name = suffix.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(suffix)"
        return destination.deletingLastPathComponent().appendingPathComponent(name)
    }
}

/// Makes Gatekeeper treat a saved file as coming from the internet, as a browser would.
public enum DownloadQuarantine {
    /// No origin URL is recorded: drive links are signed, and this attribute outlives the download.
    /// Best effort, because volumes without extended attributes (exFAT, some shares) refuse it,
    /// and that should not cost the user a finished download.
    public static func mark(_ file: URL) {
        let properties: [String: Any] = ["LSQuarantineAgentName": "Thermo", "LSQuarantineType": "LSQuarantineTypeWebDownload"]
        try? (file as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }
}
