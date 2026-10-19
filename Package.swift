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
        .library(name: "AgentCore", targets: ["AgentCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "ThermoKit", dependencies: ["CSMC"]),
        .target(name: "CTokenData", linkerSettings: [.linkedLibrary("z")]),
        // Userspace-only diagnostics; kept out of ThermoKit so the root helper never links it.
        // UI strings and translations; the root helper never links it.
        .target(name: "ThermoL10n"),
        .target(name: "AgentDoctor", dependencies: ["ThermoL10n", "AgentCore", "CTokenData", .product(name: "Markdown", package: "swift-markdown")]),
        // What both agent features read: processes, live sessions, plugins, protected paths. User-level only.
        .target(name: "AgentCore"),
        // Disk cleanup runs as the user only: the root helper must never link it.
        .target(name: "CleanKit", dependencies: ["AgentCore", "ThermoL10n"]),
        .executableTarget(name: "thermo", dependencies: ["ThermoKit", "AgentCore", "AgentDoctor", "CleanKit", "ThermoL10n"]),
        .executableTarget(name: "ThermoHelper", dependencies: ["ThermoKit"]),
        .executableTarget(
            name: "ThermoApp",
            dependencies: ["ThermoKit", "AgentDoctor", "CleanKit", "ThermoL10n", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Charts")]
        ),
        .testTarget(name: "ThermoCLITests", dependencies: ["thermo"]),
        .testTarget(name: "ThermoAppTests", dependencies: ["ThermoApp", "ThermoKit", "CleanKit", "AgentCore", "AgentDoctor"]),
        .testTarget(name: "ThermoKitTests", dependencies: ["ThermoKit", "CSMC"]),
        .testTarget(name: "ThermoHelperTests", dependencies: ["ThermoHelper", "ThermoKit"]),
        .testTarget(name: "AgentDoctorTests", dependencies: ["AgentDoctor", "ThermoL10n", "AgentCore"], exclude: ["Fixtures"]),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
