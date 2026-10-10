import Foundation
import ThermoKit

private var interrupted: sig_atomic_t = 0

/// Live view. TTY: full-screen redraw on the alternate screen; otherwise (or with
/// --json/--csv) one record per sample, suitable for logging and pipes.
struct Watch {
    let app: App

    func run() throws {
        let interval = try app.args.double("interval") ?? 1
        let count = try app.args.int("count")
        let sm = try app.sampler()

        signal(SIGINT) { _ in interrupted = 1 }
        signal(SIGTERM) { _ in interrupted = 1 }

        if app.args.has("json") || app.args.has("csv") || isatty(STDOUT_FILENO) == 0 {
            try stream(sm, interval: interval, count: count)
        } else {
            try screen(sm, interval: interval, count: count)
        }
    }

    private func stream(_ sm: Sampler, interval: Double, count: Int?) throws {
        var n = 0
        let csv = app.args.has("csv")
        let json = app.args.has("json") || !csv
        while interrupted == 0 {
            let s = sm.sample()
            if csv {
                if n == 0 { print(Export.csvStreamHeader(s)) }
                print(Export.csvStreamRow(s))
            } else if json {
                print(Export.json(app.filtered(s), pretty: false))
            }
            fflush(stdout)
            n += 1
            if let count, n >= count { break }
            sleepInterruptibly(interval)
        }
    }

    private func screen(_ sm: Sampler, interval: Double, count: Int?) throws {
        let term = RawTerminal()
        defer { term.restore() }
        print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")

        var cpuHistory: [Double] = []
        var page = 0   // 0 overview, 1 all temps, 2 power
        var n = 0
        let pages = ["overview", "sensors", "power"]

        loop: while interrupted == 0 {
            let s = sm.sample()
            if let c = s.hottest { cpuHistory.append(c) }
            let width = terminalWidth()
            if cpuHistory.count > width - 14 { cpuHistory.removeFirst(cpuHistory.count - max(1, width - 14)) }

            draw(s, model: sm.discovery.model, page: page, history: cpuHistory, interval: interval)

            n += 1
            if let count, n >= count { break }

            // Wait for the next tick, reacting to keys immediately.
            let deadline = Date().addingTimeInterval(interval)
            var dimensions = (terminalWidth(), terminalHeight())
            while interrupted == 0 {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                guard let key = term.readKey(timeout: remaining) else {
                    let current = (terminalWidth(), terminalHeight())
                    if current != dimensions {
                        dimensions = current
                        draw(s, model: sm.discovery.model, page: page, history: cpuHistory, interval: interval)
                    }
                    continue
                }
                switch key {
                case "q", "Q", "\u{1B}": break loop
                case "1", "2", "3": page = Int(key)! - 1
                case "\u{1B}[C", "l", "\t": page = (page + 1) % pages.count
                case "\u{1B}[D", "h": page = (page + pages.count - 1) % pages.count
                default: continue
                }
                draw(s, model: sm.discovery.model, page: page, history: cpuHistory, interval: interval)
            }
        }
    }

    static func contentRows(height: Int) -> Int { max(0, height - 2) }

    private func draw(_ s: Snapshot, model: String, page: Int, history: [Double], interval: Double) {
        let pages = ["overview", "sensors", "power"]
        let height = terminalHeight()
        // Leave the last column empty to avoid terminals' pending-wrap behavior.
        let columns = max(0, terminalWidth() - 1)
        let r = app.renderer
        var lines = r.header(s, model: model)
        lines.append("")
        switch page {
        case 1: lines += r.temperatures(s)
        case 2: lines += r.join([r.power(s), r.battery(s.battery)])
        default:
            lines += r.join([r.overview(s), r.fans(s), r.summaryPower(s), r.battery(s.battery)])
            if history.count > 1 {
                lines += ["", app.style.bold("History") + app.style.dim(" (hottest)"),
                          "  " + app.style.sparkline(history, lo: 30, hi: 100)
                              + "  " + app.style.temp(history.last, width: 0)]
            }
        }
        let tabs = pages.enumerated().map { i, p in i == page ? app.style.bold("[\(i + 1) \(p)]") : app.style.dim(" \(i + 1) \(p) ") }
        let footer: String
        if columns < 12 {
            footer = app.style.dim("q quit")
        } else if columns < 70 {
            footer = app.style.dim("q quit · 1-3 pages")
        } else {
            footer = tabs.joined(separator: " ") + app.style.dim(String(format: "   every %.1fs · q quit · ←/→ or 1-3 switch", interval))
        }

        lines = Array(lines.prefix(Self.contentRows(height: height)))
        var frame = "\u{1B}[H"
        for l in lines { frame += TerminalLayout.fit(l, columns: columns) + "\u{1B}[K\r\n" }
        frame += "\u{1B}[J\u{1B}[\(height);1H" + TerminalLayout.fit(footer, columns: columns) + "\u{1B}[K"
        print(frame, terminator: "")
        fflush(stdout)
    }

    private func sleepInterruptibly(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while interrupted == 0 && Date() < end { usleep(UInt32(min(0.05, max(0, end.timeIntervalSinceNow)) * 1e6)) }
    }
}

/// Puts stdin in non-canonical, no-echo mode for single-key input.
final class RawTerminal {
    private var original = termios()
    private let active: Bool
    private var input = TerminalInput()
    private var escapeDeadline: Date?

    init() {
        active = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &original) == 0
        guard active else { return }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    func restore() {
        print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")
        fflush(stdout)
        if active { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
    }

    /// Check signals at least every 100 ms and never overflow poll's Int32 timeout.
    static func pollTimeout(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite else { return 100 }
        return Int32(max(1, min(100, seconds * 1000)))
    }

    /// Returns a key (escape sequences kept whole) or nil on timeout.
    func readKey(timeout: TimeInterval) -> String? {
        if let key = input.next() { escapeDeadline = nil; return key }
        if input.awaitingEscape && escapeDeadline == nil { escapeDeadline = Date().addingTimeInterval(0.1) }
        let wait = escapeDeadline.map { min(timeout, max(0, $0.timeIntervalSinceNow)) } ?? timeout
        let milliseconds = Self.pollTimeout(wait)
        guard active else { usleep(UInt32(milliseconds) * 1000); return nil }
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, milliseconds) > 0 else {
            if let deadline = escapeDeadline, deadline <= Date() {
                escapeDeadline = nil
                return input.next(expireEscape: true)
            }
            return nil
        }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { return nil }
        input.append(Array(buf.prefix(n)))
        if let key = input.next() { escapeDeadline = nil; return key }
        if input.awaitingEscape && escapeDeadline == nil { escapeDeadline = Date().addingTimeInterval(0.1) }
        return nil
    }
}
