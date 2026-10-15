import Foundation

enum FanSampler {
    static func read(_ fans: [FanDescriptor], hasForceKey: Bool,
                     limits: [Int: (min: Double?, max: Double?)],
                     read: (FourCC) throws -> Double) -> [FanReading] {
        let forceBits = hasForceKey ? (try? read("FS! ")) : nil
        return fans.map { fan in
            let rpm = try? read(fan.actualKey)
            let mode = fan.hasModeKey ? (try? read(fan.modeKey)) : nil
            let manual = FanModeReader.manual(mode: mode, hasModeKey: fan.hasModeKey,
                                              forceBits: forceBits, hasForceKey: hasForceKey, fan: fan.index)
            let range = limits[fan.index] ?? (nil, nil)
            return FanReading(id: fan.index, name: fan.name, rpm: rpm, min: range.min, max: range.max,
                              target: manual == true ? try? read(fan.targetKey) : nil, manual: manual)
        }
    }
}
