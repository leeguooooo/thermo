import ConnectionsFeature
import NativeFeatureAPI

/// Assembly only. Feature targets keep their own models and views internal.
enum BuiltinNativeFeatures {
    @MainActor static var registrations:[NativeFeatureDefinition] {[ConnectionsFeature.registration()]}
}
