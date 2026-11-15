import ThermoL10n

package enum StoreCategory {
    package static func title(_ name: String) -> String {
        switch name.lowercased() {
        case "collaboration": return tr("Collaboration")
        case "productivity": return tr("Productivity")
        case "tools": return tr("Tools")
        case "games": return tr("Games")
        case "learning": return tr("Learning")
        case "development": return tr("Development")
        case "monitoring": return tr("Monitoring")
        default: return name
        }
    }

}
