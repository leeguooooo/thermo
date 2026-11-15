package enum StoreCategory {
    package static func title(_ name: String,localize:(String)->String) -> String {
        switch name.lowercased() {
        case "collaboration": return localize("Collaboration")
        case "productivity": return localize("Productivity")
        case "tools": return localize("Tools")
        case "games": return localize("Games")
        case "learning": return localize("Learning")
        case "development": return localize("Development")
        case "monitoring": return localize("Monitoring")
        default: return name
        }
    }

}
