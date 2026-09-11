// LinterTests.swift — end-to-end behaviour: a real binary plus a manifest in,
// findings out. These are the tests that would catch a regression a user
// would actually notice.

import XCTest
@testable import XCPrivacyLintCore

final class LinterTests: XCTestCase {

    private func lint(manifest: String?, strict: Bool = false) throws -> LintReport {
        try XCTSkipUnless(Fixture.clangAvailable, "clang not available")
        let app = try Fixture.makeApp(manifest: manifest)
        let jobs = try resolveJobs(target: app.appPath, manifest: nil, binary: nil)
        return try Linter().run(job: XCTUnwrap(jobs.first), strict: strict)
    }

    func testFlagsMissingDeclaration() throws {
        // Binary uses FileTimestamp and DiskSpace; manifest declares neither.
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: []))
        let missing = report.findings.filter { $0.kind == .missingDeclaration }

        XCTAssertEqual(Set(missing.map(\.category)), [
            "NSPrivacyAccessedAPICategoryFileTimestamp",
            "NSPrivacyAccessedAPICategoryDiskSpace"
        ])
        XCTAssertTrue(missing.allSatisfy { $0.severity == .error })
        XCTAssertEqual(report.exitCode, 2)
    }

    func testNamesTheTriggeringSymbol() throws {
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: []))
        let diskSpace = try XCTUnwrap(
            report.findings.first { $0.category == "NSPrivacyAccessedAPICategoryDiskSpace" }
        )
        // A finding that does not say *why* is not actionable.
        XCTAssertEqual(diskSpace.trigger?.name, "statfs")
        XCTAssertEqual(diskSpace.trigger?.kind, .symbol)
        XCTAssertFalse(diskSpace.suggestedReasons.isEmpty)
    }

    func testFlagsOverDeclaration() throws {
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: [
            ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"]),
            ("NSPrivacyAccessedAPICategoryDiskSpace", ["E174.1"]),
            ("NSPrivacyAccessedAPICategoryActiveKeyboards", ["3EC4.1"])   // unused
        ]))

        let over = report.findings.filter { $0.kind == .overDeclared }
        XCTAssertEqual(over.map(\.category), ["NSPrivacyAccessedAPICategoryActiveKeyboards"])
        XCTAssertEqual(over.first?.severity, .warning)
        // Warnings alone are a soft failure.
        XCTAssertEqual(report.exitCode, 1)
    }

    func testStrictModeEscalatesOverDeclaration() throws {
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: [
            ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"]),
            ("NSPrivacyAccessedAPICategoryDiskSpace", ["E174.1"]),
            ("NSPrivacyAccessedAPICategoryActiveKeyboards", ["3EC4.1"])
        ]), strict: true)

        XCTAssertEqual(report.findings.first { $0.kind == .overDeclared }?.severity, .error)
        XCTAssertEqual(report.exitCode, 2)
    }

    func testFlagsInvalidReasonCode() throws {
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: [
            ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"]),
            ("NSPrivacyAccessedAPICategoryDiskSpace", ["NOTAREAL.1"])
        ]))

        let invalid = try XCTUnwrap(report.findings.first { $0.kind == .invalidReasonCode })
        XCTAssertEqual(invalid.category, "NSPrivacyAccessedAPICategoryDiskSpace")
        XCTAssertEqual(invalid.severity, .error)
        XCTAssertTrue(invalid.message.contains("NOTAREAL.1"))
    }

    func testCleanManifestProducesNoHardFindings() throws {
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: [
            ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"]),
            ("NSPrivacyAccessedAPICategoryDiskSpace", ["E174.1"])
        ]))

        XCTAssertTrue(report.findings.allSatisfy { $0.severity == .info },
                      "unexpected: \(report.findings.filter { $0.severity != .info }.map(\.message))")
        XCTAssertEqual(report.exitCode, 0)
    }

    /// A bundle with no manifest at all is the common real-world case for an
    /// SDK that has never been audited. It must report every category, not
    /// crash and not silently pass.
    func testMissingManifestIsTreatedAsEmpty() throws {
        let report = try lint(manifest: nil)
        XCTAssertNil(report.manifestPath)
        XCTAssertEqual(report.findings.filter { $0.kind == .missingDeclaration }.count, 2)
        XCTAssertEqual(report.exitCode, 2)
    }

    func testSuccessfulMatchesAreInfoOnly() throws {
        let report = try lint(manifest: Fixture.manifest(accessedAPIs: [
            ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"]),
            ("NSPrivacyAccessedAPICategoryDiskSpace", ["E174.1"])
        ]))
        let matches = report.findings.filter { $0.kind == .successfulMatch }
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy { $0.severity == .info })
    }
}
