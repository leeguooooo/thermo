import Foundation

/// Bounds on a scene's own rendered pixels. No screen capture or system grant is involved.
public enum ModuleSnapshot {
    public static let maxBytes = 32 * 1024 * 1024
    public static let maxDimension = 8192
    public static let maxPixels = 16 * 1024 * 1024

    /// Check the PNG header before asking an image decoder to allocate its pixel buffer.
    public static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 33, data.count <= maxBytes else { return nil }
        let bytes = Array(data.prefix(24))
        guard Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { return nil }
        func integer(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
        let width = integer(16), height = integer(20)
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width * height <= maxPixels else { return nil }
        return (width, height)
    }
}
