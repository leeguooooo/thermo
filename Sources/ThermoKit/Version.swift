/// Single source of truth for the marketing version; scripts/build.sh reads it and
/// derives the build number from the git commit count.
public enum ThermoVersion {
    public static let string = "1.2.1"
}
