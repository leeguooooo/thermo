import Foundation
import ThermoL10n

public enum AppSizeState: String, Codable, Sendable {
    case unmeasured, complete, incomplete, unavailable
}

public enum AppSize {
    public static func text(_ bytes: Int64, state: AppSizeState) -> String {
        switch state {
        case .complete: return ByteFormat.string(bytes)
        case .incomplete: return bytes > 0 ? tr("at least %1$@", ByteFormat.string(bytes)) : tr("Size unavailable")
        case .unavailable: return tr("Size unavailable")
        case .unmeasured: return tr("Not measured")
        }
    }

    public static func combined(_ states: [AppSizeState], bytes: Int64) -> AppSizeState {
        if states.allSatisfy({ $0 == .complete }) { return .complete }
        if bytes > 0 { return .incomplete }
        if states.contains(.unavailable) || states.contains(.incomplete) { return .unavailable }
        return .unmeasured
    }

    static func measured(_ size: TreeSize, exists: Bool) -> AppSizeState {
        if !exists { return .unavailable }
        if size.denied || size.incomplete {
            return max(size.bytes, size.allocated) > 0 ? .incomplete : .unavailable
        }
        return .complete
    }
}

extension InstalledApp {
    public var bundleSizeState: AppSizeState { sizeState ?? (bytes > 0 ? .incomplete : .unmeasured) }
    public var bundleSizeText: String { AppSize.text(bytes, state: bundleSizeState) }
    public var leftoverSizeState: AppSizeState {
        let states = leftovers.map(\.effectiveSizeState)
        return AppSize.combined(states + [relatedDataState ?? (leftovers.isEmpty ? .unmeasured : .incomplete)], bytes: leftoverBytes)
    }
    public var totalSizeState: AppSizeState { AppSize.combined([bundleSizeState, leftoverSizeState], bytes: totalBytes) }
    public var totalSizeText: String { AppSize.text(totalBytes, state: totalSizeState) }
}

extension AppLeftover {
    public var effectiveSizeState: AppSizeState { sizeState ?? (bytes > 0 ? .incomplete : .unavailable) }
    public var sizeText: String { AppSize.text(bytes, state: effectiveSizeState) }
}

extension UninstallPlan {
    public var sizeText: String { AppSize.text(bytes, state: sizeState ?? (bytes > 0 ? .incomplete : .unavailable)) }
}

extension OrphanData {
    public var sizeState: AppSizeState { AppSize.combined(items.map(\.effectiveSizeState), bytes: bytes) }
    public var sizeText: String { AppSize.text(bytes, state: sizeState) }
}
