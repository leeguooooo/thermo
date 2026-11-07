import Carbon
import Foundation

/// With a Chinese/Japanese input method active, typing a launcher query such as `xtsz` or `chrome`
/// goes into the input method's composition first. While the search panel is open, switch to the
/// user's ASCII keyboard layout (ABC, US…) and put the previous input method back on close —
/// unless the user picked another source themselves in the meantime.
@MainActor final class SearchInputSource {
    static let shared = SearchInputSource()
    static let preferenceKey = "dev.thermo.search.switchToASCIIInput"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    private var previous: TISInputSource?
    private var selected: TISInputSource?

    func panelWillShow() {
        guard Self.enabled, previous == nil,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              !Self.isKeyboardLayout(current),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              TISSelectInputSource(ascii) == noErr else { return }
        previous = current; selected = ascii
    }

    func panelDidHide() {
        defer { previous = nil; selected = nil }
        guard let previous, let selected,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.identifier(current) == Self.identifier(selected) else { return }
        TISSelectInputSource(previous)
    }

    /// Plain layouts (ABC, US, Dvorak…) type letters directly; input methods and modes compose.
    static func isKeyboardLayout(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardLayout as String)
    }

    static func identifier(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
