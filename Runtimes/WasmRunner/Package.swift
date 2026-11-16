// swift-tools-version:6.0
import PackageDescription

// The WebAssembly runner for sandboxed third-party modules (#46). A package of its own because
// WasmKit needs macOS 15 while Thermo itself supports macOS 13: the app only starts this runner on
// macOS 15 and later, built-in features never depend on it.
let package = Package(
    name: "WasmRunner",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ThermoWasmRunner", targets: ["ThermoWasmRunner"]),
        .executable(name: "thermo-wat2wasm", targets: ["thermo-wat2wasm"]),
    ],
    dependencies: [
        // Exact: the runner executes untrusted code, so an interpreter update is a reviewed change.
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.4.2"),
    ],
    targets: [
        .target(name: "WasmRunnerCore", dependencies: [.product(name: "WasmKit", package: "WasmKit")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ThermoWasmRunner", dependencies: ["WasmRunnerCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Development only: turns the .wat fixtures into the .wasm files checked in next to them.
        .executableTarget(name: "thermo-wat2wasm", dependencies: [.product(name: "WAT", package: "WasmKit")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WasmRunnerCoreTests",
                    dependencies: ["WasmRunnerCore", .product(name: "WAT", package: "WasmKit")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
