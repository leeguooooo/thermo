// Ported from YunX-Desktop (AGPL-3.0): data/network/LanzouCrypto.kt.
import Foundation

/// The acw_sc__v2 cookie. Lanzou answers some pages with a script page holding a 40 hex digit `arg1`;
/// reordering it and XORing with a fixed mask gives the cookie. A fixed string transform, no script is run.
enum LanzouCrypto {
    /// The character at 1-based position positions[z] of arg1 goes to slot z.
    private static let positions = [
        15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
        39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36,
    ]
    private static let mask = Array("3000176000856006061501533003690027800375")

    static func acwScV2(_ arg1: String) -> String {
        let source = Array(arg1)
        var reordered = [Character](repeating: "0", count: positions.count)
        for (x, character) in source.enumerated() {
            for (z, position) in positions.enumerated() where position == x + 1 { reordered[z] = character }
        }
        var result = ""
        var i = 0
        while i + 2 <= reordered.count, i + 2 <= mask.count {
            let a = Int(String(reordered[i...(i + 1)]), radix: 16) ?? 0
            let b = Int(String(mask[i...(i + 1)]), radix: 16) ?? 0
            result += String(format: "%02x", a ^ b)
            i += 2
        }
        return result
    }

    /// The cookie value to set when the page is a challenge page; nil when it has no `arg1`.
    static func challengeCookie(_ source: String) -> String? {
        guard let arg1 = LanzouText.first(#"\barg1\s*=\s*'([0-9A-Fa-f]{40})'"#, in: source) else { return nil }
        return acwScV2(arg1)
    }
}
