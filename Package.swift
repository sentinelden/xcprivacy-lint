// swift-tools-version: 5.9
//
// xcprivacy-lint — validate iOS privacy manifests against binary API surfaces.
// See DESIGN.md for the architecture and roadmap.
//
// Two targets:
//   1. `XCPrivacyLintCore` — the static-analysis library. Importable into other
//      tools (e.g., an Xcode build-phase script that wants programmatic access
//      to findings).
//   2. `xcprivacy-lint` — the CLI executable. Wraps the core in argument
//      parsing, input format detection, and report rendering.
//
// Plus a test target for the core. The CLI is intentionally thin — almost all
// behavior lives in the core, which is what we test.

import PackageDescription

let package = Package(
    name: "xcprivacy-lint",
    platforms: [
        // macOS 13 lines up with Apple's published minimum for current Xcode
        // command-line tools. Lower would work for pure-CLI use but would
        // complicate Foundation feature flags.
        .macOS(.v13)
    ],
    products: [
        .executable(name: "xcprivacy-lint", targets: ["xcprivacy-lint"]),
        .library(name: "XCPrivacyLintCore", targets: ["XCPrivacyLintCore"])
    ],
    dependencies: [
        // Apple's argument-parser. Provides --flag and subcommand wiring with
        // free `--help` and shell completions.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // YAML decoder for the symbol→category map at Resources/symbols.yaml.
        // Yams is the canonical Swift YAML library and stable enough to pin.
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.1")
    ],
    targets: [
        // ── CLI executable ─────────────────────────────────────────────────
        .executableTarget(
            name: "xcprivacy-lint",
            dependencies: [
                "XCPrivacyLintCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/xcprivacy-lint"
        ),
        // ── Core static-analysis library ───────────────────────────────────
        .target(
            name: "XCPrivacyLintCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/XCPrivacyLintCore",
            resources: [
                // The symbol→category map ships embedded in the binary so the
                // CLI is single-file-distributable. Contributors edit the YAML
                // and rebuild; no separate config file at runtime.
                .copy("Resources/symbols.yaml")
            ]
        ),
        // ── Tests for the core ────────────────────────────────────────────
        .testTarget(
            name: "XCPrivacyLintCoreTests",
            dependencies: ["XCPrivacyLintCore"],
            path: "Tests/XCPrivacyLintCoreTests"
        )
    ]
)
