// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "thermo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "thermo", targets: ["thermo"]),
        .executable(name: "thermo-helper", targets: ["ThermoHelper"]),
        .executable(name: "ThermoApp", targets: ["ThermoApp"]),
        .library(name: "ThermoKit", targets: ["ThermoKit"]),
        .library(name: "AgentDoctor", targets: ["AgentDoctor"]),
        .library(name: "ThermoL10n", targets: ["ThermoL10n"]),
        .library(name: "CleanKit", targets: ["CleanKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "ThermoKit", dependencies: ["CSMC"]),
        // Userspace-only diagnostics; kept out of ThermoKit so the root helper never links it.
        // UI strings and translations; the root helper never links it.
        .target(name: "ThermoL10n"),
        .target(name: "AgentDoctor", dependencies: ["ThermoL10n"]),
        // Disk cleanup runs as the user only: the root helper must never link it.
        .target(name: "CleanKit"),
        .executableTarget(name: "thermo", dependencies: ["ThermoKit", "AgentDoctor", "CleanKit"]),
        .executableTarget(name: "ThermoHelper", dependencies: ["ThermoKit"]),
        .executableTarget(
            name: "ThermoApp",
            dependencies: ["ThermoKit", "AgentDoctor", "CleanKit", "ThermoL10n", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Charts")]
        ),
        .testTarget(name: "ThermoKitTests", dependencies: ["ThermoKit", "CSMC"]),
        .testTarget(name: "AgentDoctorTests", dependencies: ["AgentDoctor", "ThermoL10n"]),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
