import SwiftUI
import ThermoL10n

/// The menu bar panel lays feature rows out as small tiles; Settings shows them as full rows.
private struct FeatureRowCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    package var featureRowCompact: Bool {
        get { self[FeatureRowCompactKey.self] }
        set { self[FeatureRowCompactKey.self] = newValue }
    }
}

/// A feature that opens its own panel (Clean Screen, Keep awake…): symbol, name, a status on the
/// right and a chevron, like a row in System Settings. A green dot marks one that is running.
package struct FeatureRow: View {
    let title: String
    let symbol: String
    var status: String? = nil
    var statusColor: Color = Theme.textTertiary
    var active = false
    /// A problem to show under the row.
    var note: String? = nil
    package init(title:String,symbol:String,status:String? = nil,statusColor:Color = Theme.textTertiary,active:Bool = false,note:String? = nil) {
        self.title=title;self.symbol=symbol;self.status=status;self.statusColor=statusColor;self.active=active;self.note=note
    }
    @Environment(\.featureRowCompact) private var compact

    package var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: compact ? Theme.Space.s : Theme.Space.m) {
                Image(systemName: symbol).font(.system(size: compact ? 11 : 13, weight: .medium))
                    .foregroundStyle(active ? Theme.good : Theme.textSecondary).frame(width: compact ? 14 : 18)
                    .accessibilityHidden(true)
                Text(title).font(compact ? Theme.secondary : Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if active { Circle().fill(Theme.good).frame(width: 6, height: 6).accessibilityLabel(tr("On")) }
                if let status { Text(status).font(Theme.caption).foregroundStyle(statusColor).lineLimit(1) }
                if !compact {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            if let note {
                Text(note).font(Theme.caption).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, compact ? 22 : 30)
            }
        }
        .padding(.horizontal, compact ? Theme.Space.s + 2 : Theme.Space.l)
        .padding(.vertical, compact ? Theme.Space.s : Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 44, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight(radius: compact ? Theme.radiusSmall : 0)
    }
}

