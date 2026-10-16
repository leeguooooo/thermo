import Foundation

/// Stores only an explicitly chosen age, never a selection or cleanup plan.
struct ConversationRetentionPreferences {
    static let key = "dev.thermo.clean.session-retention.v1"
    static let choices = [1,7,30,90,180,365]
    private struct Value: Codable { var version: Int; var days: Int }
    var read: () -> Int?
    var write: (Int?) -> Void
    var persistent: Bool

    static let transient = Self(read:{ nil },write:{ _ in },persistent:false)

    static func stored(in defaults: UserDefaults) -> Self {
        .init(read:{
            guard let data=defaults.data(forKey:key),data.count <= 1024,
                  let value=try? JSONDecoder().decode(Value.self,from:data),value.version == 1,
                  choices.contains(value.days) else { return nil }
            return value.days
        },write:{ days in
            guard let days else { defaults.removeObject(forKey:key);return }
            guard choices.contains(days),let data=try? JSONEncoder().encode(Value(version:1,days:days)) else { return }
            defaults.set(data,forKey:key)
        },persistent:true)
    }
}
