// Linter.swift — the public entry point of the static-analysis core.
//
// Top-down call shape:
//   1. CLI hands us a BinaryAnalysisJob
//   2. We delegate to MachOReader to extract symbol references + ObjC classes
//   3. CategoryResolver maps each symbol to (Optional<APICategory>, suggestedReasons)
//   4. PrivacyManifestReader parses the declared categories
//   5. We diff the two sets and produce Finding values
//
// Everything below this header is intentionally a stub. See DESIGN.md §5 for
// the architecture and §9 for the v0.1 roadmap.

import Foundation

public enum LinterError: Error {
    case binaryNotReadable(path: String)
    case manifestNotReadable(path: String)
    case unsupportedMachOFormat
    case malformedSymbolMap(underlying: Error)
}

public enum Severity: String, Sendable, Codable, Hashable {
    case error          // hard finding — would fail App Store review
    case warning        // soft finding — over-declared category, unused reason
    case info           // neutral — successful match, surfaced under --verbose
}

public enum FindingKind: String, Sendable, Codable, Hashable {
    case missingDeclaration       // Binary uses API, manifest doesn't declare → error
    case overDeclared             // Manifest declares, binary doesn't use → warning
    case invalidReasonCode        // Declared reason isn't valid for the category → error
    case successfulMatch          // Successfully matched (verbose only)
}

public struct FindingTrigger: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case symbol, objcMethod, none }
    public let kind: Kind
    public let name: String                       // symbol name or "Class.method"
    public let section: String?                   // __TEXT, __DATA, etc.
}

public struct Finding: Sendable, Codable, Hashable {
    public let severity: Severity
    public let category: String                   // e.g. "NSPrivacyAccessedAPICategoryFileTimestamp"
    public let kind: FindingKind
    public let trigger: FindingTrigger?
    public let suggestedReasons: [String]
    public let message: String
}

public struct LintReport: Sendable, Codable {
    public let target: String
    public let manifestPath: String?
    public let findings: [Finding]

    /// Per CLI exit-code contract.
    public var exitCode: Int32 {
        let hardCount = findings.filter { $0.severity == .error }.count
        let softCount = findings.filter { $0.severity == .warning }.count
        if hardCount > 0 { return 2 }
        if softCount > 0 { return 1 }
        return 0
    }
}

public struct Linter {
    public init() {}

    /// Run the lint pipeline for a single binary + manifest pair.
    ///
    /// - Parameter job: input job from the CLI's input-format detection layer.
    /// - Parameter strict: when true, over-declarations are escalated from
    ///   `.warning` to `.error`. CI environments typically set this.
    ///
    /// - Throws: `LinterError` on unparseable input.
    public func run(job: BinaryAnalysisJob, strict: Bool = false) throws -> LintReport {
        // TODO(v0.1):
        //   let machO = try MachOReader(path: job.binaryPath).parse()
        //   let resolver = try CategoryResolver()
        //   let needed: Set<RequiredCategory> = resolver.resolve(machO)
        //   let declared: PrivacyManifest = job.manifestPath
        //       .map { try PrivacyManifestReader().read(path: $0) }
        //       ?? .empty
        //   return Differ.report(target: job.binaryPath,
        //                        manifestPath: job.manifestPath,
        //                        needed: needed,
        //                        declared: declared,
        //                        strict: strict)
        return LintReport(
            target: job.binaryPath,
            manifestPath: job.manifestPath,
            findings: []
        )
    }
}
