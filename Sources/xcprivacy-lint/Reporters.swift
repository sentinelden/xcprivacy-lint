// Reporters.swift: render a LintReport in each output format.
//
// Four formats, three audiences:
//   .text   humans at a terminal
//   .json   scripts and downstream tooling
//   .gh     GitHub Actions workflow commands, inline annotations on the diff
//   .sarif  GitHub code scanning, findings in the Security tab, with history
//
// SARIF is the one that matters for adoption. Workflow annotations vanish when
// the run is deleted; SARIF results persist, get deduplicated across runs, and
// can gate a branch protection rule.

import Foundation
import XCPrivacyLintCore

enum Reporter {

    // MARK: - Text

    static func text(_ report: LintReport, verbose: Bool, version: String) -> String {
        var out: [String] = []
        out.append("xcprivacy-lint \(version) · checking \(URL(fileURLWithPath: report.target).lastPathComponent)")
        out.append("")

        let visible = report.findings.filter { verbose || $0.severity != .info }
        if visible.isEmpty {
            out.append(report.findings.isEmpty
                ? "No required-reason API usage detected, and nothing declared. Clean."
                : "All declared categories match the binary's API surface. Clean.")
            out.append("")
            return out.joined(separator: "\n")
        }

        for finding in visible.sorted(by: severityOrder) {
            let tag: String
            switch finding.severity {
            case .error:   tag = "[ERROR]  "
            case .warning: tag = "[WARN]   "
            case .info:    tag = "[ OK ]   "
            }
            // Indent continuation lines under the tag so the message block
            // reads as one unit.
            let lines = finding.message
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            out.append(tag + (lines.first ?? ""))
            for line in lines.dropFirst() where !line.isEmpty {
                out.append(String(repeating: " ", count: 9) + line)
            }
            out.append("")
        }

        let errors = report.findings.filter { $0.severity == .error }.count
        let warnings = report.findings.filter { $0.severity == .warning }.count
        out.append("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s").")
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: - JSON

    static func json(_ report: LintReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    // MARK: - GitHub Actions workflow commands

    static func githubAnnotations(_ report: LintReport) -> String {
        let file = report.manifestPath.map(relativeToWorkingDirectory) ?? ""
        return report.findings
            .filter { $0.severity != .info }
            .map { finding in
                let level = finding.severity == .error ? "error" : "warning"
                // Workflow commands are newline-delimited; %0A is the escape
                // for an embedded newline inside one annotation.
                let message = finding.message
                    .replacingOccurrences(of: "\n", with: "%0A")
                    .replacingOccurrences(of: ",", with: "%2C")
                let location = file.isEmpty ? "" : "file=\(file),line=1,"
                return "::\(level) \(location)title=\(finding.category)::\(message)"
            }
            .joined(separator: "\n")
    }

    // MARK: - SARIF 2.1.0

    static func sarif(_ report: LintReport, version: String) throws -> String {
        let uri = report.manifestPath.map(relativeToWorkingDirectory)
            ?? relativeToWorkingDirectory(report.target)

        // One rule per finding kind. GitHub groups results by ruleId in the
        // Security tab, so kind-level granularity keeps the list readable
        // while the category stays in the message and the fingerprint.
        let kinds: [(FindingKind, String, String)] = [
            (.missingDeclaration, "Missing required-reason declaration",
             "The binary references an API in a required-reason category that the privacy manifest does not declare. App Store review rejects this."),
            (.overDeclared, "Declared but unused category",
             "The privacy manifest declares a required-reason category that no symbol or selector in the binary maps to."),
            (.invalidReasonCode, "Invalid reason code",
             "The privacy manifest declares a reason code that Apple does not define for that category."),
            (.successfulMatch, "Declaration matches binary",
             "Informational: a declared category matched references found in the binary.")
        ]

        let rules: [[String: Any]] = kinds.map { kind, name, description in
            [
                "id": "xcprivacy-lint/\(kind.rawValue)",
                "name": name,
                "shortDescription": ["text": name],
                "fullDescription": ["text": description],
                "helpUri": "https://github.com/sentinelden/xcprivacy-lint#findings",
                "defaultConfiguration": ["level": kind == .missingDeclaration || kind == .invalidReasonCode ? "error" : "warning"]
            ]
        }

        let results: [[String: Any]] = report.findings
            .filter { $0.severity != .info }
            .map { finding in
                var result: [String: Any] = [
                    "ruleId": "xcprivacy-lint/\(finding.kind.rawValue)",
                    "level": finding.severity == .error ? "error" : "warning",
                    "message": ["text": finding.message.replacingOccurrences(of: "\n", with: " ")],
                    "locations": [[
                        "physicalLocation": [
                            "artifactLocation": ["uri": uri],
                            "region": ["startLine": 1]
                        ]
                    ]]
                ]
                // Stable across runs so GitHub can track a finding's lifetime
                // even when line numbers move.
                result["partialFingerprints"] = [
                    "xcprivacyLintFinding/v1": "\(finding.kind.rawValue):\(finding.category)"
                ]
                return result
            }

        let sarif: [String: Any] = [
            "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
            "version": "2.1.0",
            "runs": [[
                "tool": ["driver": [
                    "name": "xcprivacy-lint",
                    "informationUri": "https://github.com/sentinelden/xcprivacy-lint",
                    "version": version,
                    "rules": rules
                ]],
                "results": results
            ]]
        ]

        let data = try JSONSerialization.data(
            withJSONObject: sarif,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    /// GitHub resolves SARIF and annotation paths relative to the repository
    /// root, which is the working directory inside an Action step.
    private static func relativeToWorkingDirectory(_ path: String) -> String {
        let cwd = FileManager.default.currentDirectoryPath
        guard path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }

    private static func severityOrder(_ a: Finding, _ b: Finding) -> Bool {
        func rank(_ s: Severity) -> Int {
            switch s {
            case .error: return 0
            case .warning: return 1
            case .info: return 2
            }
        }
        if rank(a.severity) != rank(b.severity) { return rank(a.severity) < rank(b.severity) }
        return a.category < b.category
    }
}
