# xcprivacy-lint

> Validate your iOS app's `PrivacyInfo.xcprivacy` against the API surface its binary actually touches. Catches a real class of manifest mistake before App Store review does, with [known limits](#what-it-can-and-cannot-see) on Swift-native calls.

[![CI](https://github.com/sentinelden/xcprivacy-lint/actions/workflows/ci.yml/badge.svg)](https://github.com/sentinelden/xcprivacy-lint/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9+-orange.svg)](https://swift.org)

```
$ xcprivacy-lint MyApp.ipa

xcprivacy-lint 0.1.0 · checking MyApp.ipa

[ERROR]  Missing required declaration: NSPrivacyAccessedAPICategoryFileTimestamp
         Triggered by symbol `getattrlist` (called in __TEXT section).
         Add the category with reason 3B52.1 or C617.1 to your manifest.

[ OK ]   NSPrivacyAccessedAPICategorySystemBootTime, declared with reason 35F9.1.
```

## Why

Every iOS app since iOS 17 must ship a `PrivacyInfo.xcprivacy` manifest declaring its use of Apple's required-reason API categories. Apple's reviewer catches missing declarations on submission and rejects the build, a 24-hour-plus feedback loop you discover *after* pushing to TestFlight.

`xcprivacy-lint` closes that loop locally: scans your `.app`, `.ipa`, `.xcframework`, or `.xcarchive`, compares the binary's API surface against the manifest, and reports findings in under 10 seconds.

## Status

**v0.2, working.** Parses thin and fat Mach-O (32- and 64-bit, both endiannesses), resolves `.app`, `.ipa`, `.xcframework` and `.xcarchive` inputs, and reports missing declarations, over-declarations and invalid reason codes. The symbol reader is verified against `nm` in the test suite.

Category coverage is deliberately narrow (the five categories Apple publishes) and extending it is a one-file PR. See [Contributing](#contributing).

## Install

```sh
brew install sentinelden/tap/xcprivacy-lint
```

For now, build from source:

```sh
git clone https://github.com/sentinelden/xcprivacy-lint
cd xcprivacy-lint
swift build -c release
./.build/release/xcprivacy-lint --help
```

## Usage

```sh
# Validate a TestFlight build before submission.
xcprivacy-lint ~/Builds/MyApp-1.2.3.ipa

# Per-slice validation of a distributed framework.
xcprivacy-lint ./build/MySDK.xcframework

# CI mode: machine-readable, fail-on-findings.
xcprivacy-lint --format json --strict MyApp.ipa

# GitHub Actions annotations.
xcprivacy-lint --format gh ./build/MyApp.app

# SARIF for GitHub code scanning.
xcprivacy-lint --format sarif --output results.sarif ./build/MyApp.app

# Diagnose a suspected false negative: dump everything the reader saw.
xcprivacy-lint --binary ./build/MyApp.app/MyApp --dump-symbols | grep statfs
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Clean, no findings |
| `1`  | Soft findings only (over-declared categories) |
| `2`  | Hard findings, would fail App Store review |
| `64` | Usage / argument error |
| `65` | Unparseable input |

## Findings

For each of Apple's [required-reason API categories](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api):

- **Missing declaration**: the binary calls a category symbol but the manifest does not declare the category. Hard finding (Apple rejects).
- **Over-declaration**: the manifest declares a category but the binary touches no matching symbol. Soft warning.
- **Invalid reason code**: the manifest declares a reason code not valid for the category. Hard finding.

### What it can and cannot see

This is binary analysis. It reads the Objective-C selectors and imported symbols present in the compiled image, and it can only report what is actually there.

**It sees APIs that go through the Objective-C runtime.** `UserDefaults.standard` leaves `standardUserDefaults`; `FileManager.attributesOfItem(atPath:)` leaves `attributesOfItemAtPath:error:`. These match reliably.

**It cannot see Swift-native Foundation calls that the compiler inlines.** The clearest example is `URL.resourceValues(forKeys:)`, the idiomatic way to read disk space and file timestamps in Swift. It leaves no selector, no imported symbol, and no string in the binary. There is nothing to match on, and no addition to `symbols.yaml` can change that.

Two consequences, and the second one matters more:

- **Over-declaration warnings can be false positives.** A category you declare correctly may be reported as unused because the call that justifies it is invisible.
- **Missing-declaration errors can be false negatives.** If your only use of a category is through an inlined Swift call, this tool will not flag the missing declaration, and App Store review still will.

Measured on eight production apps: of twelve over-declaration warnings, **four were false positives**, every one of them caused by a `URL.resourceValues(forKeys:)` read that the binary does not record. Three were `volumeAvailableCapacityForImportantUsageKey` (disk space) and one was `contentModificationDateKey` (file timestamp). That call pattern appeared in five of the eight apps, so this is the common case in Swift code rather than an edge case.

The one hard error the tool reported in that run was a true positive: an app shipping no manifest at all while calling `NSUserDefaults.boolForKey:`. Objective-C-bridged APIs are exactly where this approach still works.

So treat a clean run as "no problems I can see in the binary", not as "this manifest is correct". Closing the gap needs source-level analysis rather than binary analysis; see [Contributing](#contributing).

Currently-supported categories:

- `NSPrivacyAccessedAPICategoryFileTimestamp`
- `NSPrivacyAccessedAPICategorySystemBootTime`
- `NSPrivacyAccessedAPICategoryDiskSpace`
- `NSPrivacyAccessedAPICategoryActiveKeyboards`
- `NSPrivacyAccessedAPICategoryUserDefaults`

The symbol → category mapping lives at [`Sources/XCPrivacyLintCore/Resources/symbols.yaml`](./Sources/XCPrivacyLintCore/Resources/symbols.yaml). Updates as Apple announces new categories are PRs to that single file, no Swift code changes needed.

## What it does NOT do

- **Dynamic analysis.** No spawning, no debugger attachment, no runtime observation. Static analysis is what Apple uses; matching that surface is enough.
- **General iOS privacy compliance scoring.** Findings only, no "you scored 87%."
- **Replacement for Apple's submission validator.** We approximate well enough to catch common failures before submission; Apple is authoritative. See [What it can and cannot see](#what-it-can-and-cannot-see) for where the approximation breaks down.

See [`DESIGN.md` §3](./DESIGN.md#3-non-goals) for the full non-goals list.

## CI integration

### GitHub Action

```yaml
# .github/workflows/privacy.yml
permissions:
  contents: read
  security-events: write     # required for the Security tab upload

jobs:
  privacy:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme MyApp -derivedDataPath build
      - uses: sentinelden/xcprivacy-lint@v0.2.0
        with:
          target: build/Build/Products/Debug-iphoneos/MyApp.app
          strict: true
```

Findings land in the repository's **Security → Code scanning** tab, deduplicated across runs and tracked as they open and close. Set `fail-on-findings: false` to report without blocking the build while you work through a backlog.

### Without the Action

```yaml
- name: Validate PrivacyInfo.xcprivacy
  run: |
    brew install sentinelden/tap/xcprivacy-lint
    xcprivacy-lint --format gh --strict ./build/MyApp.app
```

`--format gh` emits GitHub Actions annotations consumed by the workflow UI. `--strict` makes over-declarations exit non-zero alongside missing declarations.

## Architecture

Brief; full version in [`DESIGN.md`](./DESIGN.md).

```
target (.app / .ipa / .xcframework / .xcarchive)
   │
   ▼
[Mach-O parser] → symbol table + ObjC class/method refs
                                   │
                                   ▼
                          [Symbol → category map] (Resources/symbols.yaml)
                                   │
                                   ▼
                          required-category set
                                   │
[PrivacyInfo parser] → declared-category set ──┐
                                                ├─→ diff → findings
                          required-category set ┘
                                   │
                                   ▼
                   [Reporter: text | json | gh-actions | sarif]
```

Three independently-testable layers: input extraction, static analysis core (`XCPrivacyLintCore` library), and report rendering.

## Contributing

PRs welcome. The most valuable contributions today are:

1. **Symbol coverage**: adding entries to `Resources/symbols.yaml` for categories or symbols we missed. Each addition should reference Apple's docs and include a test asserting a known binary triggers the lookup.
2. **Source-level analysis.** The largest accuracy gap is Swift-native Foundation calls that inline away, leaving nothing in the binary. A SwiftSyntax pass over the source could find `URL.resourceValues(forKeys:)` and friends and cross-check them against the manifest, turning today's false positives and false negatives into real findings. This is the single most valuable thing anyone could add.
3. **Objective-C precision**: selectors are currently matched without their receiving class, because recovering the receiver means walking `__objc_selrefs` back through class metadata. Distinctive selectors make this sound in practice, but a binary that defines its own `-systemUptime` would produce a false positive. A correct receiver walk would close that gap.
4. **Output formats**: plain markdown for PR-comment bots; a Danger plugin.

Run the test suite:

```sh
swift test
```

## License

MIT. See [`LICENSE`](./LICENSE).

## Who builds this

[Sentinel Den](https://sentinelden.com): iOS security research and runtime-defense SDKs from Vancouver, BC. We ship four commercial iOS SDKs ([SentinelSDK](https://sentinelden.com/sdk/sentinel), [CryptoShield](https://sentinelden.com/sdk/cryptoshield), [AgenticGuard](https://sentinelden.com/sdk/agenticguard), [EnclaveVault](https://sentinelden.com/sdk/enclavevault)) and the [Sentinel Studio](https://sentinelden.com/studio) macOS auditor. xcprivacy-lint is our open-source flank: same engineering rigor, MIT-licensed.
