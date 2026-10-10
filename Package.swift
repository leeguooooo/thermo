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
        .target(name: "AgentDoctor"),
        .executableTarget(name: "thermo", dependencies: ["ThermoKit", "AgentDoctor"]),
        .executableTarget(name: "ThermoHelper", dependencies: ["ThermoKit"]),
        .executableTarget(
            name: "ThermoApp",
            dependencies: ["ThermoKit", "AgentDoctor", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Charts")]
        ),
        .testTarget(name: "ThermoKitTests", dependencies: ["ThermoKit", "CSMC"]),
        .testTarget(name: "AgentDoctorTests", dependencies: ["AgentDoctor"]),
    ],
    swiftLanguageVersions: [.v5]
)
