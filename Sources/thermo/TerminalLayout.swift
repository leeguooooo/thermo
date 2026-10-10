import Foundation

/// Fits one terminal row without splitting ANSI styles or composed characters.
enum TerminalLayout {
    static func fit(_ text: String, columns: Int) -> String {
        guard columns > 0 else { return "" }
        var output = ""
        var used = 0
        var styled = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{1B}" {
                let start = index
                index = text.index(after: index)
                guard index < text.endIndex, text[index] == "[" else { continue }
                index = text.index(after: index)
                while index < text.endIndex, text[index].isNumber || text[index] == ";" {
                    index = text.index(after: index)
                }
                if index < text.endIndex, text[index] == "m" {
                    index = text.index(after: index)
                    output += text[start..<index]
                    styled = true
                }
                continue
            }
            index = text.index(after: index)
            // Sensor names must not move the cursor or introduce extra rows.
            guard !character.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { continue }
            let width = cellWidth(character)
            guard used + width <= columns else { break }
            output.append(character)
            used += width
        }
        if styled { output += "\u{1B}[0m" }
        return output
    }

    static func cellWidth(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xfe0f }) { return 2 }
        return scalars.map { scalar in
            let value = scalar.value
            // Wide/full-width Unicode ranges, independent of the CLI's C locale.
            if (0x1100...0x115f).contains(value) || value == 0x2329 || value == 0x232a ||
                (0x2e80...0xa4cf).contains(value) && value != 0x303f ||
                (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value) ||
                (0xfe10...0xfe19).contains(value) || (0xfe30...0xfe6f).contains(value) ||
                (0xff00...0xff60).contains(value) || (0xffe0...0xffe6).contains(value) ||
                (0x20000...0x3fffd).contains(value) { return 2 }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format: return 0
            default: return 1
            }
        }.max() ?? 0
    }
}
