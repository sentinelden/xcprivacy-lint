# xcprivacy-lint

> Validate your iOS app's `PrivacyInfo.xcprivacy` against the API surface its binary actually touches. Catches missing and over-declared required-reason categories before App Store review does.

[![CI](https://github.com/sentinelden/xcprivacy-lint/actions/workflows/ci.yml/badge.svg)](https://github.com/sentinelden/xcprivacy-lint/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9+-orange.svg)](https://swift.org)

```
$ xcprivacy-lint MyApp.ipa

xcprivacy-lint 0.1.0 · checking MyApp.ipa

[ERROR]  Missing required declaration: NSPrivacyAccessedAPICategoryFileTimestamp
         Triggered by symbol `getattrlist` (called in __TEXT section).
         Add the category with reason 3B52.1 or C617.1 to your manifest.

[ OK ]   NSPrivacyAccessedAPICategorySystemBootTime — declared with reason 35F9.1.
```

## Why

Every iOS app since iOS 17 must ship a `PrivacyInfo.xcprivacy` manifest declaring its use of Apple's required-reason API categories. Apple's reviewer catches missing declarations on submission and rejects the build — a 24-hour-plus feedback loop you discover *after* pushing to TestFlight.

`xcprivacy-lint` closes that loop locally: scans your `.app`, `.ipa`, `.xcframework`, or `.xcarchive`, compares the binary's API surface against the manifest, and reports findings in under 10 seconds.

## Status

**Pre-v0.1 scaffolding.** Design and skeleton are in place; see [`DESIGN.md`](./DESIGN.md). Contributions welcome.

## Install (future state — not yet published)

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
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Clean — no findings |
| `1`  | Soft findings only (over-declared categories) |
| `2`  | Hard findings — would fail App Store review |
| `64` | Usage / argument error |
| `65` | Unparseable input |

## What it checks

For each of Apple's [required-reason API categories](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api):

- **Missing declaration** — the binary calls a category symbol but the manifest does not declare the category. Hard finding (Apple rejects).
- **Over-declaration** — the manifest declares a category but the binary touches no matching symbol. Soft warning.
- **Invalid reason code** — the manifest declares a reason code not valid for the category. Hard finding.

Currently-supported categories:

- `NSPrivacyAccessedAPICategoryFileTimestamp`
- `NSPrivacyAccessedAPICategorySystemBootTime`
- `NSPrivacyAccessedAPICategoryDiskSpace`
- `NSPrivacyAccessedAPICategoryActiveKeyboards`
- `NSPrivacyAccessedAPICategoryUserDefaults`

The symbol → category mapping lives at [`Sources/XCPrivacyLintCore/Resources/symbols.yaml`](./Sources/XCPrivacyLintCore/Resources/symbols.yaml). Updates as Apple announces new categories are PRs to that single file — no Swift code changes needed.

## What it does NOT do

- **Dynamic analysis.** No spawning, no debugger attachment, no runtime observation. Static analysis is what Apple uses; matching that surface is enough.
- **General iOS privacy compliance scoring.** Findings only, no "you scored 87%."
- **Replacement for Apple's submission validator.** We approximate well enough to catch common failures before submission; Apple is authoritative.

See [`DESIGN.md` §3](./DESIGN.md#3-non-goals) for the full non-goals list.

## CI integration

```yaml
# .github/workflows/ci.yml
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
                            [Reporter: text | json | gh-actions]
```

Three independently-testable layers: input extraction, static analysis core (`XCPrivacyLintCore` library), and report rendering.

## Contributing

PRs welcome. The most valuable contributions today are:

1. **Symbol coverage** — adding entries to `Resources/symbols.yaml` for categories or symbols we missed. Each addition should reference Apple's docs and include a test asserting a known binary triggers the lookup.
2. **Input format support** — `.xcarchive` walking, `.xcframework` per-slice handling.
3. **Output formats** — SARIF for IDE integrations, plain markdown for PR-comment bots.

Run the test suite:

```sh
swift test
```

## License

MIT. See [`LICENSE`](./LICENSE).

## Who builds this

[Sentinel Den](https://sentinelden.com) — iOS security research and runtime-defense SDKs from Vancouver, BC. We ship four commercial iOS SDKs ([SentinelSDK](https://sentinelden.com/sdk/sentinel), [CryptoShield](https://sentinelden.com/sdk/cryptoshield), [AgenticGuard](https://sentinelden.com/sdk/agenticguard), [EnclaveVault](https://sentinelden.com/sdk/enclavevault)) and the [Sentinel Studio](https://sentinelden.com/studio) macOS auditor. xcprivacy-lint is our open-source flank — same engineering rigor, MIT-licensed.
