# xcprivacy-lint — design doc

**Status:** draft / scaffolding · **Owner:** Muhammad Khan · **Last updated:** 2026-05-10

A CLI that validates an iOS app or framework's `PrivacyInfo.xcprivacy` declaration against the actual API surface its binary touches. Catches missing and over-declared required-reason API categories before App Store submission does.

---

## 1. The problem

Every iOS app since iOS 17.0 must ship a `PrivacyInfo.xcprivacy` manifest that declares, for each of Apple's required-reason API categories the app touches, a reason code explaining why. Apple's static analyzer scans submitted binaries at App Store review time and rejects apps where:

- **A required-reason API is called but the category is not declared.** (Hard reject; common cause of last-minute submission failures.)
- **A category is declared but no matching API is touched.** (Soft warning; clutters the privacy report developers eventually publish via App Store Connect.)
- **A declared reason code is not valid for the category.** (Reject.)

Today, the only way most developers discover any of the above is when Apple's reviewer system rejects their build. That's a 24-hour-plus feedback cycle. For teams who ship via TestFlight on a weekly cadence, this is a real productivity tax.

`xcprivacy-lint` closes that loop locally and in CI. Run it against a `.app`, `.ipa`, `.xcarchive`, or `.xcframework`, and it tells you exactly what's missing and what's over-declared, with the specific Apple reason code(s) you should use.

## 2. Goals

1. **Catch what Apple's reviewer catches**, locally, before submission. Same set of categories, same reason codes, same precision.
2. **Single-file binary distribution.** A solo iOS dev should be able to `brew install xcprivacy-lint && xcprivacy-lint MyApp.ipa` and get useful output in under 10 seconds.
3. **CI-friendly.** JSON output, GitHub-Actions annotation output, non-zero exit codes on findings.
4. **Easy to keep current with Apple's category list.** New reason codes ship in WWDC announcements; updating the lint to recognize them should be a YAML edit, not a Swift refactor.
5. **Permissively licensed open-source utility** (MIT). Encourages contribution; the value is in the symbol→category mapping accuracy and the binary-parsing UX, not in the code being proprietary.

## 3. Non-goals

- **Dynamic analysis.** We do not spawn the app, attach a debugger, or observe runtime calls. Static analysis is what Apple uses; matching that surface is enough.
- **Replacement for Apple's submission validator.** Apple has authoritative answers; we approximate them well enough to catch the common failures before submission.
- **General iOS privacy compliance scoring.** No "you scored 87% on App Store privacy"; we report concrete findings against the declared manifest only.
- **Cross-platform.** macOS-only at first (because Mach-O parsing is the natural fit). Linux compat is a future possibility.
- **Closed-source.** This is the open-source utility flank of the Sentinel Den lineup; the value is reach.

## 4. High-level approach

```
        ┌─────────────┐         ┌──────────────────┐
        │  Target     │  parse  │  Parsed binary   │
        │  (.app /    │ ──────▶ │  · Mach-O hdrs   │
        │   .ipa /    │         │  · symbol table  │
        │   .xcfwk)   │         │  · ObjC classes  │
        └─────────────┘         └────────┬─────────┘
                                          │ lookup
                                          ▼
                                ┌──────────────────────┐
                                │  Symbol→Category map │
                                │  (Resources/         │
                                │     symbols.yaml)    │
                                └────────┬─────────────┘
                                          │ produces
                                          ▼
                                ┌──────────────────────┐
                                │  Required categories │  ┌──────────┐
                                │  (set + reasoning)   │──│  Diff    │
                                └──────────────────────┘  │          │
                                                          │          │
        ┌─────────────┐                                   │          │
        │ PrivacyInfo │  parse                            │          │
        │ .xcprivacy  │ ──────▶ ┌──────────────────────┐  │          │
        └─────────────┘         │ Declared categories  │──│          │
                                └──────────────────────┘  └────┬─────┘
                                                                │
                                                                ▼
                                                    ┌──────────────────────┐
                                                    │   Findings report    │
                                                    │   (text / JSON /     │
                                                    │    GH-Actions)       │
                                                    └──────────────────────┘
```

## 5. Architecture

Three layers, each independently testable:

### 5.1 Input format detector + extractor

Single entry point that auto-detects the input format and yields a list of `(binaryPath, manifestPath)` pairs:

- `.ipa` → unzip to temp dir, find `Payload/<App>.app/<binary>` + `PrivacyInfo.xcprivacy`
- `.app` → walk for the binary and the embedded manifest
- `.xcframework` → enumerate slices, return one pair per slice
- `.xcarchive` → walk to `Products/Applications/<App>.app`, same as `.app`
- Raw Mach-O + `--manifest <path>` flag → bypass detection

Output: `[BinaryAnalysisJob]`, each with a binary path and a (possibly missing) manifest path.

### 5.2 Static analysis core (`XCPrivacyLintCore`)

The reusable library that does the actual work. Three modules:

**`MachOReader`** — parses Mach-O binaries (fat or thin), walks load commands, extracts:
- `LC_SYMTAB` symbol names (C / Swift mangled)
- `LC_DYLD_INFO_ONLY` lazy bindings (external symbols resolved at runtime)
- Objective-C class and method references via `__objc_classlist`, `__objc_classname`, `__objc_methname` sections
- Swift symbols via the mangled-name prefix `_$s` and demangling (via the `swift-demangle` binary if present, falling back to raw mangled names if not — both work for category lookup)

**`PrivacyManifestReader`** — parses `PrivacyInfo.xcprivacy` via `PropertyListDecoder`. Strongly-typed model:

```swift
public struct PrivacyManifest: Decodable {
    public let NSPrivacyTracking: Bool
    public let NSPrivacyTrackingDomains: [String]
    public let NSPrivacyCollectedDataTypes: [CollectedDataType]
    public let NSPrivacyAccessedAPITypes: [AccessedAPI]
}

public struct AccessedAPI: Decodable {
    public let NSPrivacyAccessedAPIType: String      // "NSPrivacyAccessedAPICategoryFileTimestamp"
    public let NSPrivacyAccessedAPITypeReasons: [String]  // ["C617.1"]
}
```

**`CategoryResolver`** — the soul of the tool. Reads `Resources/symbols.yaml` (the symbol→category map; see §6 below) and provides:

```swift
public func category(forSymbol symbol: String) -> APICategory?
public func category(forObjCClass cls: String, method: String?) -> APICategory?
public func validReasons(for category: APICategory) -> Set<String>
```

The map is loaded once per run and queried per-symbol.

### 5.3 Reporter

Takes the diff result and emits findings in one of three formats:

- **`text` (default)** — coloured human-readable output, grouped by severity
- **`json`** — schema-stable JSON for CI tooling
- **`github-actions`** — `::warning file=...,line=...::msg` annotations consumed by GitHub Actions UI

Exit codes:
- `0` — clean run, no findings
- `1` — soft findings only (over-declared categories, unused reasons)
- `2` — hard findings (missing required-reason declarations — would fail Apple review)
- `64` — usage / input error
- `65` — unparseable input (corrupt binary, malformed manifest)

## 6. Symbol → category mapping

This is the highest-value, most-frequently-updated component. Lives at `Sources/XCPrivacyLintCore/Resources/symbols.yaml` and is embedded into the binary at build time via SwiftPM's `.copy` resource directive. Contributors update the YAML; one Swift rebuild emits a new binary with the updated mappings.

Each entry has the form:

```yaml
- category: NSPrivacyAccessedAPICategoryFileTimestamp
  valid_reasons: [0A2A.1, 3B52.1, 8FFB.1, C617.1, DDA9.1]
  symbols:
    - getattrlist
    - getattrlistbulk
    - fgetattrlist
    - stat
    - lstat
    - fstat
    - "$s10Foundation11URLResourceKey...modificationDateKey"   # Swift mangled
  objc_methods:
    - class: NSFileManager
      methods: [attributesOfItemAtPath:error:, modificationDate]
    - class: NSURL
      methods: [getResourceValue:forKey:error:]
  notes: |
    Touched whenever code reads file timestamps via FileManager APIs
    or the lower-level POSIX calls. Reason codes:
      0A2A.1 — Display file timestamps to the user
      3B52.1 — Inside-app functionality requiring file timestamps
      8FFB.1 — Inside-app optimization
      C617.1 — Files inside the app container, app group, or temp dir
      DDA9.1 — Apple Music API
```

### 6.1 Bootstrap content

For v0.1, hand-curate the map for the five categories currently published by Apple:

- `NSPrivacyAccessedAPICategoryFileTimestamp`
- `NSPrivacyAccessedAPICategorySystemBootTime`
- `NSPrivacyAccessedAPICategoryDiskSpace`
- `NSPrivacyAccessedAPICategoryActiveKeyboards`
- `NSPrivacyAccessedAPICategoryUserDefaults`

…with the canonical reason codes per Apple's docs. Source: <https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api>.

### 6.2 Currency

Apple announces new categories at WWDC and patches the list mid-year. The repo's CI runs a daily check against Apple's docs URL (HTTP GET + hash compare) and opens a maintenance issue when the page changes, prompting a manual sync.

## 7. CLI surface

```
USAGE:
    xcprivacy-lint [OPTIONS] <target>
    xcprivacy-lint --manifest <path> --binary <path>

ARGUMENTS:
    <target>     Path to .app, .ipa, .xcframework, or .xcarchive

OPTIONS:
    --manifest <path>           Override the manifest location (advanced)
    --binary <path>             Override the binary location (advanced)
    --format <text|json|gh>     Output format (default: text)
    --strict                    Treat over-declarations as hard findings
    --quiet                     Suppress informational output; findings only
    --verbose                   Show resolved symbol→category matches
    --help                      Print usage
    --version                   Print version
```

### Examples

```bash
# Validate a TestFlight build before submission.
xcprivacy-lint ~/Builds/MyApp-1.2.3.ipa

# Per-slice validation of a distributed framework.
xcprivacy-lint ./build/MySDK.xcframework

# CI mode: machine-readable, fail-on-findings.
xcprivacy-lint --format json --strict MyApp.ipa

# GitHub Actions annotations.
xcprivacy-lint --format gh ./build/MyApp.app
```

## 8. Output examples

### Text mode (default)

```
xcprivacy-lint 0.1.0 · checking MyApp.ipa

Target:   Payload/MyApp.app/MyApp (arm64)
Manifest: Payload/MyApp.app/PrivacyInfo.xcprivacy

[ERROR]  Missing required declaration: NSPrivacyAccessedAPICategoryFileTimestamp
         Triggered by symbol `getattrlist` (called in __TEXT section).
         Add the category with reason 3B52.1 or C617.1 to your manifest.

[WARN]   Over-declared: NSPrivacyAccessedAPICategoryUserDefaults
         Declared in manifest but no UserDefaults symbol references found.
         Either remove the declaration or check this is intended.

[ OK ]   NSPrivacyAccessedAPICategorySystemBootTime — declared with reason 35F9.1.
         3 call sites resolved (ProcessInfo.systemUptime).

Findings: 1 error, 1 warning, 1 ok.
Exit code: 2 (hard findings — would fail App Store review).
```

### JSON mode

```json
{
  "tool": "xcprivacy-lint",
  "version": "0.1.0",
  "target": "Payload/MyApp.app/MyApp",
  "manifest": "Payload/MyApp.app/PrivacyInfo.xcprivacy",
  "findings": [
    {
      "severity": "error",
      "category": "NSPrivacyAccessedAPICategoryFileTimestamp",
      "kind": "missing_declaration",
      "trigger": { "kind": "symbol", "name": "getattrlist", "section": "__TEXT" },
      "suggested_reasons": ["3B52.1", "C617.1"]
    }
  ],
  "summary": { "error": 1, "warning": 1, "ok": 1 },
  "exit_code": 2
}
```

## 9. Roadmap

### v0.1 (this scaffolding)

- Mach-O reader for thin + fat ARM64 binaries
- Manifest parser
- Hand-curated symbol map for the 5 currently-known categories
- Text + JSON output
- `.app` and raw binary input
- `--strict` flag, exit codes per §5.3
- README, LICENSE, CI on push

### v0.2

- `.ipa` extraction (unzip + walk)
- `.xcframework` enumeration (one report per slice)
- `.xcarchive` walking
- GitHub-Actions annotation format

### v0.3

- Swift symbol demangling (via embedded `libswiftDemangle` or fall-back to raw matching)
- ObjC class/method resolution via `__objc_classlist` walking
- Reason-code validity check (declared reason not in `valid_reasons` for the category → error)

### v1.0

- Homebrew tap (`brew install sentinelden/tap/xcprivacy-lint`)
- macOS-signed + notarized binary releases on GitHub Releases
- Automated category-map sync (CI scrapes Apple's docs nightly, opens PR on diff)

### Stretch

- Linux build (musl-static via Swift toolchain) for use in cross-platform CI
- Xcode build-phase script template (`Run Script: xcprivacy-lint $TARGET_BUILD_DIR/$EXECUTABLE_PATH || true`)

## 10. Open questions

- **How to handle private frameworks linked against in production?** Apple's required-reason list applies only to public-API category APIs. A private API that calls `getattrlist` internally probably isn't surfaced in the parent app's symbols. Worth surveying.
- **Demangling Swift symbols robustly.** Embedding `libswiftDemangle` ties us to a specific Swift runtime. Shelling out to `xcrun swift demangle` is simpler but adds a launch-time dependency. v0.1: raw matching; v0.3: revisit.
- **Multiple architectures in a fat binary.** Should xcprivacy-lint validate each slice independently or union their symbol sets? Probably the latter — the manifest applies to the whole bundle.
- **xcframework slice metadata.** When validating an xcframework slice, the manifest lives at the framework root, not per-slice. Need to confirm Apple's expectation.

## 11. Non-functional requirements

- **Performance:** 10s end-to-end for a 100 MB IPA on Apple Silicon. Mach-O parsing is the bottleneck (single-pass walk); manifest read is microseconds.
- **Distribution:** static binary at first; Homebrew formula by v1.0. No runtime dependencies beyond macOS itself.
- **Telemetry:** none. The tool is offline, single-process. Findings stay local.
- **Security:** signed + notarized binaries from v1.0; signature verification documented for users.

## 12. Related work

- **Apple's privacy-manifest static analyzer.** Authoritative; runs at submission. We replicate, locally.
- **`fastlane` precheck.** Pre-submission validation; does not currently include privacy-manifest checks.
- **`SwiftLint`.** Different domain (Swift style); cited only as reference for the CLI distribution pattern via Homebrew tap.

## 13. Reciprocal value to Sentinel Den

Open-source utility published under `github.com/sentinelden/xcprivacy-lint`. Three indirect benefits:

1. **Discovery channel.** Developers searching "validate iOS privacy manifest" find the repo, click through to the org, discover the SDK lineup.
2. **Authority signal.** A correctly-maintained, well-tested open-source utility in the privacy-manifest space demonstrates Sentinel Den ships real engineering rigor.
3. **First-party dogfooding.** Each Sentinel Den SDK ships with a `PrivacyInfo.xcprivacy`; using xcprivacy-lint internally raises the bar across the suite.
