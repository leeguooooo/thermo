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
        .library(name: "SearchCore", targets: ["SearchCore"]),
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", exact: "1.6.0"),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "ThermoKit", dependencies: ["CSMC"]),
        .target(name: "MenuBarCore"),
        .target(name: "CMenuBar", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "CTokenData", linkerSettings: [.linkedLibrary("z")]),
        // Userspace-only diagnostics; kept out of ThermoKit so the root helper never links it.
        // UI strings and translations; the root helper never links it.
        .target(name: "ThermoL10n"),
        .target(name: "AgentDoctor", dependencies: ["ThermoL10n", "AgentCore", "CTokenData", .product(name: "Markdown", package: "swift-markdown"), .product(name: "Yams", package: "Yams")]),
        // What both agent features read: processes, live sessions, plugins, protected paths. User-level only.
        .target(name: "AgentCore"),
        .systemLibrary(name: "CSQLite"),
        // Local search runs as the user; never linked into the privileged helper.
        .target(name: "SearchCore", dependencies: ["CSQLite"], linkerSettings: [.linkedFramework("CoreServices")]),
        .target(name: "CWebPEncoder", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")]),
        .target(name: "CaptureCore", dependencies: ["CWebPEncoder"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Vision"), .linkedFramework("AVFoundation")]),
        // Disk cleanup runs as the user only: the root helper must never link it.
        .target(name: "CleanKit", dependencies: ["AgentCore", "ThermoL10n"]),
        .executableTarget(name: "thermo", dependencies: ["ThermoKit", "AgentCore", "AgentDoctor", "CleanKit", "ThermoL10n", "SearchCore"]),
        .executableTarget(name: "ThermoHelper", dependencies: ["ThermoKit"]),
        .executableTarget(
            name: "ThermoApp",
            dependencies: ["ThermoKit", "AgentDoctor", "CleanKit", "ThermoL10n", "SearchCore", "CaptureCore", "MenuBarCore", "CMenuBar", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Charts"), .linkedFramework("AVKit"), .linkedFramework("WebKit"), .linkedFramework("Quartz"),
                             .linkedFramework("CoreWLAN"), .linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio"),
                             .linkedFramework("AudioToolbox"), .linkedFramework("CoreLocation")]
        ),
        .testTarget(name: "ThermoCLITests", dependencies: ["thermo"]),
        .testTarget(name: "ThermoAppTests", dependencies: ["ThermoApp", "ThermoKit", "CleanKit", "AgentCore", "AgentDoctor", "SearchCore", "MenuBarCore"]),
        .testTarget(name: "ThermoKitTests", dependencies: ["ThermoKit", "CSMC"]),
        .testTarget(name: "ThermoHelperTests", dependencies: ["ThermoHelper", "ThermoKit"]),
        .testTarget(name: "AgentDoctorTests", dependencies: ["AgentDoctor", "ThermoL10n", "AgentCore"], exclude: ["Fixtures"]),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
        .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
