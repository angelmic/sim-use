// swift-tools-version:5.10
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

// The FB* XCFrameworks built by `scripts/build.sh` are STATIC archives
// (upstream idb switched its frameworks to MACH_O_TYPE staticlib), so the
// FB* code links into the consuming binary and nothing is loaded at
// runtime. Two consequences wired up below:
//
// 1. The FB* Swift modules import the reverse-engineered private-framework
//    Clang modules bundled with idb (CoreSimulator, SimulatorKit, ...).
//    Every target that compiles `import FBControlCore` /
//    `import FBSimulatorControl` — directly or through iOSSimBackend's
//    swiftmodule — needs those module maps on the compiler search path.
//    `scripts/build.sh` stages them under build_products/PrivateHeaders/.
// 2. The static archives defer their CoreSimulator /
//    AccessibilityPlatformTranslation class references to the final link,
//    which must weak-link the .tbd stubs (the real frameworks are loaded
//    at runtime by FBSimulatorControlFrameworkLoader).
//
// The ObjC-heavy archives are `-force_load`ed (per archive, NOT a blanket
// `-ObjC`): their category-only members (e.g. FBControlCoreLogger+OSLog)
// export no referenced symbol, so a normal archive link drops them and
// the first runtime use dies with "unrecognized selector"
// (+[FBControlCoreLoggerFactory osLoggerWithLevel:], reproduced).
// CompanionUtilities is deliberately NOT force-loaded: it is pure Swift
// (everything it provides is pulled in by ordinary symbol references),
// and force-loading it makes Xcode 26.5-built binaries abort with
// "freed pointer was not the last allocation" — a Swift task-allocator
// trap in unrelated async code (bisected per-archive; Xcode 27 B4 builds
// don't trip it).
//
// Both flag sets use `Context.packageDirectory` because SwiftPM resolves
// relative compiler/linker arguments against an unspecified working
// directory that differs between the classic and SwiftBuild backends.
// unsafeFlags make this package unusable as a SwiftPM dependency of
// another package; sim-use is a root package (CLI tool), so that is fine.
let privateHeadersDir = "\(Context.packageDirectory)/build_products/PrivateHeaders"

// The bare -I is needed too: the private headers include their siblings
// framework-style (e.g. <CoreSimulator/NSObject-Protocol.h>), which
// resolves as a subdirectory of the PrivateHeaders root.
let privateModuleMapFlags: [String] = ["-Xcc", "-I\(privateHeadersDir)"] + [
    "CoreSimulator", "SimulatorApp", "SimulatorKit", "AXRuntime",
    "AccessibilityPlatformTranslation",
].flatMap {
    ["-Xcc", "-fmodule-map-file=\(privateHeadersDir)/\($0)/module.modulemap"]
}

let fbLinkerFlags: [String] = [
    "FBControlCore", "FBSimulatorControl", "XCTestBootstrap",
].flatMap {
    [
        "-Xlinker", "-force_load",
        "-Xlinker",
        "\(Context.packageDirectory)/build_products/XCFrameworks/\($0).xcframework/macos-arm64_x86_64/\($0).framework/Versions/A/\($0)",
    ]
} + [
    "CoreSimulator", "AccessibilityPlatformTranslation",
].flatMap {
    ["-Xlinker", "-weak_library", "-Xlinker", "\(privateHeadersDir)/\($0)/\($0).tbd"]
}

let package = Package(
    name: "SimUse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "sim-use",
            targets: ["SimUse"]
        ),
        .library(
            name: "SimUseCore",
            targets: ["SimUseCore"]
        ),
        .library(
            name: "SimUseVideo",
            targets: ["SimUseVideo"]
        ),
        .library(
            name: "AndroidBackend",
            targets: ["AndroidBackend"]
        ),
        .library(
            name: "iOSSimBackend",
            targets: ["iOSSimBackend"]
        ),
        .library(
            name: "TVOSBackend",
            targets: ["TVOSBackend"]
        ),
        .library(
            name: "AppiumCore",
            targets: ["AppiumCore"]
        ),
        .library(
            name: "DeviceBackend",
            targets: ["DeviceBackend"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SimUseCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SimUseCore",
            // VERSION is consumed by the daemon (DaemonClient version-
            // check gate, DaemonServer ping response). Generating it
            // per-target is cheap and keeps the daemon dependency-free
            // of higher targets.
            plugins: ["VersionPlugin"]
        ),
        // Platform-neutral host-side video plumbing (H.264 parsing/muxing/
        // encoding, frame utilities) shared by both backends. Must stay
        // FB*-free: anything that needs FBSimulatorControl belongs in
        // iOSSimBackend, anything adb-shaped in AndroidBackend.
        .target(
            name: "SimUseVideo",
            dependencies: [
                "SimUseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SimUseVideo"
        ),
        .target(
            name: "iOSSimBackend",
            dependencies: [
                "SimUseCore",
                "SimUseVideo",
                "FBSimulatorControl",
                "FBControlCore",
                "XCTestBootstrap",
                "CompanionUtilities",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iOSSimBackend",
            swiftSettings: [
                .unsafeFlags(privateModuleMapFlags)
            ],
            plugins: ["VersionPlugin"]
        ),
        .target(
            name: "AndroidBackend",
            dependencies: [
                "SimUseCore",
                "SimUseVideo",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AndroidBackend",
            // Resources/ holds `sim-use-device-bridge.apk` at runtime
            // (built by `scripts/build-bridge.sh`). Copy the whole
            // directory so the SPM build doesn't require the APK to
            // exist at build time — `AndroidDeviceController` surfaces
            // a clear "Bridge APK not found" error when the resource
            // is missing.
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "AppiumCore",
            // The W3C WebDriver / Appium protocol layer, generalized out of
            // TVOSBackend so iOS/tvOS device backends can share one client.
            // Platform-specific capability assembly and command semantics
            // (e.g. tvOS `mobile: pressButton`) live in the backends, not here.
            dependencies: [
                "SimUseCore",
            ],
            path: "Sources/AppiumCore"
        ),
        .target(
            name: "DeviceBackend",
            // Physical Apple device (iOS/tvOS) verb engine: fail-fast
            // preflight, capability assembly, and the WebDriverAgent-backed
            // verbs (xd 2.0 Phase 1 T3). Depends only on the generic Appium
            // client and the shared core — the CLI layer (SimUse executable,
            // TVOSBackend) routes physical-device UDIDs here.
            dependencies: [
                "SimUseCore",
                "AppiumCore",
            ],
            path: "Sources/DeviceBackend",
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "TVOSBackend",
            dependencies: [
                "SimUseCore",
                "AppiumCore",
                // The tvOS command surface reuses DeviceBackend's preflight
                // and device-capability assembly for the physical Apple TV
                // path (a bare Appium session on a device needs the
                // xcodebuild-flow caps, not the Simulator ones).
                "DeviceBackend",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/TVOSBackend"
        ),
        .executableTarget(
            name: "SimUse",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SimUseCore",
                "SimUseVideo",
                "AndroidBackend",
                "iOSSimBackend",
                "TVOSBackend",
                "DeviceBackend",
                "FBSimulatorControl",
                "FBControlCore",
                "XCTestBootstrap",
                "CompanionUtilities"
            ],
            path: "Sources/SimUse",
            resources: [
                .copy("Resources/skills"),
                // Built Viewer SPA assets (Vite output). Re-generated by
                // `scripts/build-viewer.sh`; committed so `swift build`
                // works without Node on contributor machines that don't
                // touch the Viewer. The `viewer` subcommand reads this
                // tree via `Bundle.module.resourceURL` and serves it
                // out of a local HTTP listener.
                .copy("Resources/viewer"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"] + privateModuleMapFlags)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-headerpad_max_install_names",
                ] + fbLinkerFlags)
            ],
            plugins: ["VersionPlugin"]
        ),
        .testTarget(
            name: "SimUseTests",
            dependencies: ["SimUse", "iOSSimBackend", "SimUseCore", "SimUseVideo"],
            path: "Tests",
            // `Tests/` is the umbrella path; the sub-target test
            // directories below sit under it as separate testTargets.
            // List them by name in `exclude` so SwiftPM doesn't double-
            // claim their sources. Add new test sub-directories here
            // when adding new testTargets, or move them out from under
            // `Tests/` to drop this maintenance burden.
            exclude: [
                "SimUseCoreTests",
                "AndroidBackendTests",
                "TVOSBackendTests",
                "AppiumCoreTests",
                "DeviceBackendTests",
            ],
            resources: [
                .copy("README.md"),
                .copy("Fixtures")
            ],
            swiftSettings: [
                .unsafeFlags(privateModuleMapFlags)
            ],
            linkerSettings: [
                .unsafeFlags(fbLinkerFlags)
            ]
        ),
        .testTarget(
            name: "SimUseCoreTests",
            dependencies: ["SimUseCore"],
            path: "Tests/SimUseCoreTests",
            resources: [
                // Real `devicectl list devices --json-output` capture used
                // to unit-test AppleDeviceLister parsing without a device.
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "AndroidBackendTests",
            dependencies: ["AndroidBackend", "SimUseCore"],
            path: "Tests/AndroidBackendTests"
            // `Fixtures/` here is empty (`.gitkeep` only) — listing
            // it as a resource would emit a SwiftPM warning. Add a
            // `.copy("Fixtures")` entry when real fixture files
            // land.
        ),
        .testTarget(
            name: "TVOSBackendTests",
            dependencies: ["TVOSBackend", "SimUseCore"],
            path: "Tests/TVOSBackendTests"
        ),
        .testTarget(
            name: "AppiumCoreTests",
            dependencies: ["AppiumCore", "SimUseCore"],
            path: "Tests/AppiumCoreTests"
        ),
        .testTarget(
            name: "DeviceBackendTests",
            dependencies: ["DeviceBackend", "AppiumCore", "SimUseCore"],
            path: "Tests/DeviceBackendTests"
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            path: "Plugins/VersionPlugin"
        ),
        .binaryTarget(
            name: "FBControlCore",
            path: "build_products/XCFrameworks/FBControlCore.xcframework"
        ),
        .binaryTarget(
            name: "FBSimulatorControl",
            path: "build_products/XCFrameworks/FBSimulatorControl.xcframework"
        ),
        .binaryTarget(
            name: "XCTestBootstrap",
            path: "build_products/XCFrameworks/XCTestBootstrap.xcframework"
        ),
        .binaryTarget(
            name: "CompanionUtilities",
            path: "build_products/XCFrameworks/CompanionUtilities.xcframework"
        ),
    ]
)
