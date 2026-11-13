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
        .library(name: "CloudDriveKit", targets: ["CloudDriveKit"]),
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
        .library(name: "MediaToolsKit", targets: ["MediaToolsKit"]),
        .library(name: "VideoKit", targets: ["VideoKit"]),
        .library(name: "ModuleKit", targets: ["ModuleKit"]),
        .library(name: "ModuleHost", targets: ["ModuleHost"]),
        .library(name: "ModuleSDK", targets: ["ModuleSDK"]),
        .executable(name: "thermo-capture-script", targets: ["CaptureScriptWorker"]),
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
        .target(name:"CaptureScriptCore"),
        .executableTarget(name:"CaptureScriptWorker",dependencies:["CaptureScriptCore"],linkerSettings:[.linkedFramework("JavaScriptCore")]),
        .target(name: "CaptureCore", dependencies: ["CWebPEncoder"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Vision"), .linkedFramework("AVFoundation"), .linkedFramework("JavaScriptCore")]),
        // Disk cleanup runs as the user only: the root helper must never link it.
        .target(name: "CleanKit", dependencies: ["AgentCore", "ThermoL10n"]),
        // Cloud drive protocols and providers, ported from YunX. Runs as the user; the root helper must never link it.
        .target(name: "CloudDriveKit"),
        // HTTP(S) segmented downloads run as the user; never linked into the privileged helper.
        .target(name: "DownloadKit"),
        // Gopeed/FFmpeg tooling and credential backups run as the user; never linked into the privileged helper.
        .target(name: "MediaToolsKit", linkerSettings: [.linkedFramework("AVFoundation")]),
        // Video link parsing, ported from YunX. Runs as the user; never linked into the privileged helper.
        .target(name: "VideoKit", linkerSettings: [.linkedFramework("WebKit")]),
        // The contract between the kernel and feature modules: manifest, capabilities, XPC protocols. No dependencies.
        .target(name: "ModuleKit"),
        // The kernel's module manager: finds the modules inside the app and runs their processes (ExtensionKit).
        .target(name: "ModuleHost", dependencies: ["ModuleKit"], linkerSettings: [.linkedFramework("ExtensionKit"), .linkedFramework("ExtensionFoundation")]),
        // Test-only module and host for scripts/module-harness.sh; neither is copied into Thermo.app.
        // What a module links: its commands, its scenes and its connection to the kernel.
        .target(name: "ModuleSDK", dependencies: ["ModuleKit"], swiftSettings: [.unsafeFlags(["-application-extension"])],
                linkerSettings: [.linkedFramework("ExtensionKit"), .linkedFramework("ExtensionFoundation")]),
        .executableTarget(name: "ProbeModule", dependencies: ["ModuleKit", "ModuleSDK"], exclude: ["module.json"],
                          swiftSettings: [.unsafeFlags(["-application-extension"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .executableTarget(name: "ModuleHarness", dependencies: ["ModuleHost", "ModuleKit"]),
        // Build-time check of the modules packed into the app; run by scripts/build.sh, not shipped.
        .executableTarget(name: "ModuleCheck", dependencies: ["ModuleKit"]),
        .executableTarget(name: "thermo", dependencies: ["CaptureScriptCore", "ThermoKit", "AgentCore", "AgentDoctor", "CleanKit", "ThermoL10n", "SearchCore"]),
        .executableTarget(name: "ThermoHelper", dependencies: ["ThermoKit"]),
        .executableTarget(
            name: "ThermoApp",
            dependencies: ["ThermoKit", "AgentDoctor", "CleanKit", "ThermoL10n", "SearchCore", "CaptureCore", "CaptureScriptCore", "MenuBarCore", "CMenuBar", "CloudDriveKit", "DownloadKit", "MediaToolsKit", "VideoKit", "ModuleKit", "ModuleHost", .product(name: "Markdown", package: "swift-markdown"), .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Charts"), .linkedFramework("AVKit"), .linkedFramework("WebKit"), .linkedFramework("Quartz"),
                             .linkedFramework("CoreWLAN"), .linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio"),
                             .linkedFramework("AudioToolbox"), .linkedFramework("CoreLocation")]
        ),
        .testTarget(name: "ThermoCLITests", dependencies: ["thermo"]),
        .testTarget(name: "ThermoAppTests", dependencies: ["ThermoApp", "ModuleKit", "ModuleHost", "ThermoKit", "CleanKit", "AgentCore", "AgentDoctor", "SearchCore", "MenuBarCore", "CloudDriveKit", "DownloadKit", "MediaToolsKit", "VideoKit"]),
        .testTarget(name: "ThermoKitTests", dependencies: ["ThermoKit", "CSMC"]),
        .testTarget(name: "ThermoHelperTests", dependencies: ["ThermoHelper", "ThermoKit"]),
        .testTarget(name: "AgentDoctorTests", dependencies: ["AgentDoctor", "ThermoL10n", "AgentCore"], exclude: ["Fixtures"]),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"]),
        .testTarget(name:"CaptureScriptCoreTests",dependencies:["CaptureScriptCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
        .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"]),
        .testTarget(name: "CloudDriveKitTests", dependencies: ["CloudDriveKit"]),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
        .testTarget(name: "MediaToolsKitTests", dependencies: ["MediaToolsKit"]),
        .testTarget(name: "VideoKitTests", dependencies: ["VideoKit"]),
        .testTarget(name: "ModuleKitTests", dependencies: ["ModuleKit"]),
        .testTarget(name: "ModuleHostTests", dependencies: ["ModuleHost", "ModuleKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
