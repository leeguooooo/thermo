import Foundation

struct FanChartSample: Identifiable {
    let time: Date
    let fan: Int
    let segment: Int
    let rpm: Double
    var id: String { "\(time.timeIntervalSince1970):\(fan):\(segment)" }

    static func samples(_ history: [HistoryPoint]) -> [FanChartSample] {
        var segments: [Int: Int] = [:]
        var result: [FanChartSample] = []
        let count = history.map { $0.fans.count }.max() ?? 0
        for point in history {
            for index in 0..<count {
                guard point.fans.indices.contains(index), let rpm = point.fans[index], rpm.isFinite, rpm >= 0 else {
                    segments[index, default: 0] += 1
                    continue
                }
                result.append(.init(time: point.time, fan: index, segment: segments[index, default: 0], rpm: rpm))
            }
        }
        return result
    }
}
