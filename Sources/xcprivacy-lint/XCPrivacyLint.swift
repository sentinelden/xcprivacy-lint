// XCPrivacyLint.swift: CLI entry point.
//
// Deliberately not named main.swift: a file with that name is treated as
// top-level code, which is incompatible with the @main attribute.
//
// Intentionally thin. All real work lives in `XCPrivacyLintCore`; this file's
// job is argument parsing, input format detection, and report rendering.
//
// Exit code contract (see DESIGN.md §5.3):
//   0   clean run, no findings
//   1   soft findings only (over-declared categories)
//   2   hard findings, would fail App Store review
//   64  usage / argument error  (matches sysexits.h EX_USAGE)
//   65  unparseable input         (sysexits.h EX_DATAERR)

import ArgumentParser
import Foundation
import XCPrivacyLintCore

let toolVersion = "0.3.0"

@main
struct XCPrivacyLint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcprivacy-lint",
        abstract: "Validate iOS PrivacyInfo.xcprivacy against the binary's actual API surface.",
        version: toolVersion
    )

    @Argument(help: "Path to .app, .ipa, .xcframework, or .xcarchive. Omit when using --manifest + --binary.")
    var target: String?

    @Option(help: "Override manifest location (advanced; bypasses input format detection).")
    var manifest: String?

    @Option(help: "Override binary location (advanced; bypasses input format detection).")
    var binary: String?

    @Option(help: "Output format: text | json | gh | sarif. Default: text.")
    var format: OutputFormat = .text

    @Option(help: "Write the report to this path instead of stdout.")
    var output: String?

    @Flag(help: "Treat over-declared categories as hard findings (exit non-zero).")
    var strict: Bool = false

    @Flag(help: "Suppress informational output; findings only.")
    var quiet: Bool = false

    @Flag(help: "Show resolved symbol→category matches.")
    var verbose: Bool = false

    @Flag(help: "Print every symbol and selector read from the binary, then exit. Use this to diagnose a suspected false negative: if an API you expect is absent here, the binary genuinely does not reference it.")
    var dumpSymbols: Bool = false

    func run() throws {
        // ── Resolve input → list of jobs ──────────────────────────────────
        let jobs: [BinaryAnalysisJob]
        do {
            jobs = try resolveJobs(target: target, manifest: manifest, binary: binary)
        } catch let error as InputResolutionError {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            throw ExitCode(64)
        }

        // ── Symbol dump (diagnostic short-circuit) ────────────────────────
        if dumpSymbols {
            for job in jobs {
                let refs = try MachOReader(path: job.binaryPath).parse()
                print("# \(job.binaryPath)")
                print("# architectures: \(refs.architectures.joined(separator: ", "))")
                print("# \(refs.importedSymbols.count) imported symbols, \(refs.objcSelectors.count) selectors")
                for s in refs.importedSymbols.map(\.name).sorted() { print("symbol\t\(s)") }
                for s in refs.objcSelectors.sorted() { print("selector\t\(s)") }
            }
            return
        }

        // ── Lint each job ─────────────────────────────────────────────────
        let linter = Linter()
        var reports: [LintReport] = []
        for job in jobs {
            do {
                reports.append(try linter.run(job: job, strict: strict))
            } catch let error as LinterError {
                FileHandle.standardError.write(Data("error: \(describe(error))\n".utf8))
                throw ExitCode(65)
            }
        }

        // ── Render ────────────────────────────────────────────────────────
        var rendered: [String] = []
        for report in reports {
            switch format {
            case .text:
                rendered.append(Reporter.text(report, verbose: verbose, version: toolVersion))
            case .json:
                rendered.append(try Reporter.json(report))
            case .gh:
                rendered.append(Reporter.githubAnnotations(report))
            case .sarif:
                rendered.append(try Reporter.sarif(report, version: toolVersion))
            }
        }
        let body = rendered.joined(separator: "\n")

        if let output {
            try body.write(toFile: output, atomically: true, encoding: .utf8)
            if !quiet, format != .text {
                print("wrote \(format.rawValue) report to \(output)")
            }
        } else if !(quiet && format == .text) {
            print(body)
        }

        // ── Exit per contract ─────────────────────────────────────────────
        // Across multiple jobs the worst outcome wins: one failing slice of an
        // .xcframework has to fail the whole run, or CI would pass a build
        // that App Store review will reject.
        let worst = reports.map(\.exitCode).max() ?? 0
        if worst != 0 { throw ExitCode(worst) }
    }

    private func describe(_ error: LinterError) -> String {
        switch error {
        case .binaryNotReadable(let path):
            return "could not read binary at \(path)"
        case .manifestNotReadable(let path):
            return "could not parse privacy manifest at \(path)"
        case .unsupportedMachOFormat:
            return "input is not a Mach-O binary (or uses an unsupported format)"
        case .malformedSymbolMap(let underlying):
            return "bundled symbol map failed to load: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Argument types

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
    case gh
    case sarif

    var defaultValueDescription: String { "text" }
}
