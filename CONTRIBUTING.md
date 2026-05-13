# Contributing to xcprivacy-lint

Thanks for considering a contribution. This document covers what we welcome, what to expect, and the few gotchas worth knowing before opening a PR.

## What we welcome

In rough priority order:

1. **New symbols in `Resources/symbols.yaml`.** When Apple updates the [required-reason API docs](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api), we need the new symbols mapped to categories. See the [symbols.yaml gotcha](#yaml-quoting-rule-must-read) below before editing.
2. **Bug fixes** in the linter logic. Reproduction case + failing test before the fix lands.
3. **New output formats.** SARIF (for GitHub Code Scanning), JUnit XML (for CI dashboards), JSON (for downstream tooling) are all on the roadmap.
4. **Documentation improvements.** README clarifications, examples, better error messages.
5. **Performance.** If you can measurably speed up the Mach-O symbol enumeration on a large binary, send a PR with a benchmark.

## What we'd rather not see

- **PRs to add or modify the license.** xcprivacy-lint is MIT, and that's settled.
- **PRs adding non-essential dependencies.** Every dependency is a future supply-chain risk; we keep the dependency graph deliberately small (Yams, swift-argument-parser, that's it).
- **Style-only PRs.** Code formatting is enforced by Swift's default style; PRs that only reformat without changing behavior are usually closed.
- **PRs that disable tests.** If a test is wrong, fix it. If it's flaky, file an issue first.

## YAML quoting rule (must read)

If you're editing `Sources/XCPrivacyLintCore/Resources/symbols.yaml`, this is the only rule that's not obvious:

**Always quote Objective-C selector strings.**

```yaml
# WRONG: the colon-space inside the selector triggers YAML's implicit-mapping syntax
methods:
  - attributesOfItemAtPath:error:

# RIGHT: double-quoted, parses as a single string
methods:
  - "attributesOfItemAtPath:error:"
```

The YAML spec treats `:` (followed by a space or end-of-line) as the implicit-mapping separator. An unquoted `attributesOfItemAtPath:error:` is parsed as a nested mapping, not a string, and `CategoryResolverTests` fails with `Expected to decode Scalar but found Mapping instead`.

When in doubt: quote it. Quoting a string that doesn't need quoting is harmless. Forgetting to quote one that does breaks the whole file.

## Local development

```sh
git clone https://github.com/sentinelden/xcprivacy-lint.git
cd xcprivacy-lint

# Build
swift build

# Run the tests
swift test

# Run the CLI
./.build/debug/xcprivacy-lint --help
```

Xcode 16 or later is recommended. The CI pins to Xcode 16.x on macOS-14 runners; if your local Swift is older, the build may differ slightly.

## Pull request process

1. **Open an issue first** for anything non-trivial. Saves you the time of writing a PR we don't want to merge.
2. **Branch from `main`.** Name it descriptively: `add-cve-2026-1234-symbols`, `fix-macho-parser-arm64e`, `docs-readme-typo`. Avoid `feature/foo` or `update`.
3. **Write a focused PR.** One concern per PR. If you find unrelated issues while working, file them separately.
4. **Add a test.** Every new symbol mapping, every bug fix, every new output format needs a corresponding test under `Tests/`.
5. **Update `DESIGN.md` if relevant.** Architectural decisions belong there, not in PR descriptions that nobody re-reads.
6. **Run CI locally.** `swift test --parallel` mirrors the CI run. Don't push a PR that you haven't run tests on.
7. **Reference the issue.** Include `Fixes #N` or `Refs #N` in the PR body so GitHub auto-links.

## Citing sources for new symbol entries

When you add a new entry to `symbols.yaml`, **include the Apple-docs URL that supports the mapping** in the entry's `notes:` block. The maintenance burden of this file scales with how easy it is to verify entries, so we treat citations as non-optional. PRs without citations will be asked to add them before merge.

## Reporting security issues

**Do not** file public issues for security vulnerabilities. Send a private email to `security@sentinelden.com` (PGP key available on request) per the [Sentinel Den security disclosure policy](https://sentinelden.com/security#disclosure). We acknowledge within 2 business days and target a fix within 30 days for high-severity issues.

## Communication

- **Bugs** → GitHub Issues
- **Feature requests** → GitHub Issues with `enhancement` label
- **Open-ended questions** → GitHub Discussions
- **Security issues** → `security@sentinelden.com` (private)
- **Vendor / partnership inquiries** → see [sentinelden.com/contact](https://sentinelden.com/contact)

## License

By submitting a PR, you agree that your contribution is licensed under the [MIT License](LICENSE) and that you have the right to license it. No CLA, no copyright assignment, no fine print.
