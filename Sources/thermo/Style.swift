import Foundation
import ThermoKit

/// ANSI styling, disabled when stdout is not a TTY, NO_COLOR is set, or --no-color.
struct Style {
    var enabled: Bool
    var fahrenheit = false

    static func detect(noColor: Bool) -> Style {
        Style(enabled: !noColor && isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil)
    }

    func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    func bold(_ s: String) -> String { wrap(s, "1") }
    func dim(_ s: String) -> String { wrap(s, "2") }
    func red(_ s: String) -> String { wrap(s, "31") }
    func green(_ s: String) -> String { wrap(s, "32") }
    func yellow(_ s: String) -> String { wrap(s, "33") }
    func cyan(_ s: String) -> String { wrap(s, "36") }

    func heat(_ s: String, _ celsius: Double) -> String {
        celsius >= 85 ? red(s) : celsius >= 65 ? yellow(s) : green(s)
    }

    func temp(_ c: Double?, width: Int = 7) -> String {
        guard let c else { return pad("—", width, right: true) }
        let text = fahrenheit ? String(format: "%.1f°F", c * 9 / 5 + 32) : String(format: "%.1f°C", c)
        return heat(pad(text, width, right: true), c)
    }

    func bar(_ fraction: Double, width: Int, celsius: Double? = nil) -> String {
        let f = max(0, min(1, fraction.isFinite ? fraction : 0))
        let full = Int((f * Double(width)).rounded())
        let filled = String(repeating: "█", count: full)
        let rest = dim(String(repeating: "░", count: width - full))
        if let c = celsius { return heat(filled, c) + rest }
        return cyan(filled) + rest
    }

    static let sparkChars = Array("▁▂▃▄▅▆▇█")

    func sparkline(_ values: [Double], lo: Double? = nil, hi: Double? = nil) -> String {
        guard let mn = lo ?? values.min(), let mx = hi ?? values.max() else { return "" }
        let span = max(mx - mn, 0.001)
        return String(values.map { v in
            Style.sparkChars[Int(((v - mn) / span * 7).rounded()).clamped(0, 7)]
        })
    }
}

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let n = s.count
    guard n < width else { return s }
    let space = String(repeating: " ", count: width - n)
    return right ? space + s : s + space
}

func fmt(_ v: Double?, _ unit: String, digits: Int = 2) -> String {
    guard let v else { return "—" }
    return String(format: "%.\(digits)f %@", v, unit)
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}

func terminalWidth() -> Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return Int(w.ws_col) }
    return 80
}

func terminalHeight() -> Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_row > 0 { return Int(w.ws_row) }
    return 24
}
