// xcprivacy-lint — CLI entry point.
//
// Intentionally thin. All real work lives in `XCPrivacyLintCore`; this file's
// job is argument parsing, input format detection, and report rendering.
//
// Exit code contract (see DESIGN.md §5.3):
//   0   clean run, no findings
//   1   soft findings only (over-declared categories)
//   2   hard findings — would fail App Store review
//   64  usage / argument error  (matches sysexits.h EX_USAGE)
//   65  unparseable input         (sysexits.h EX_DATAERR)

import ArgumentParser
import Foundation
import XCPrivacyLintCore

@main
struct XCPrivacyLint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprivacy-lint",
        abstract: "Validate iOS PrivacyInfo.xcprivacy against the binary's actual API surface.",
        version: "0.1.0-dev"
    )

    @Argument(help: "Path to .app, .ipa, .xcframework, or .xcarchive. Omit when using --manifest + --binary.")
    var target: String?

    @Option(help: "Override manifest location (advanced; bypasses input format detection).")
    var manifest: String?

    @Option(help: "Override binary location (advanced; bypasses input format detection).")
    var binary: String?

    @Option(help: "Output format: text | json | gh. Default: text.")
    var format: OutputFormat = .text

    @Flag(help: "Treat over-declared categories as hard findings (exit non-zero).")
    var strict: Bool = false

    @Flag(help: "Suppress informational output; findings only.")
    var quiet: Bool = false

    @Flag(help: "Show resolved symbol→category matches.")
    var verbose: Bool = false

    func run() throws {
        // Resolve input → list of jobs.
        let jobs: [BinaryAnalysisJob]
        do {
            jobs = try resolveJobs(
                target: target,
                manifest: manifest,
                binary: binary
            )
        } catch let error as InputResolutionError {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            throw ExitCode(64)
        }

        // TODO(v0.1): wire up to XCPrivacyLintCore.Linter.run(job:).
        // For now, scaffold-only — print resolved jobs and exit clean.
        if !quiet {
            print("xcprivacy-lint 0.1.0-dev · resolved \(jobs.count) job(s):")
            for job in jobs {
                print("  · binary:   \(job.binaryPath)")
                print("    manifest: \(job.manifestPath ?? "<not detected>")")
            }
            print("\n(scaffolding — full lint not yet implemented; see DESIGN.md §9 roadmap)")
        }

        // Until the linter is wired up, always exit clean. Once Linter.run
        // returns findings, sum severities and exit per the contract above.
        throw ExitCode(0)
    }
}

// MARK: - Argument types

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
    case gh

    var defaultValueDescription: String { "text" }
}
