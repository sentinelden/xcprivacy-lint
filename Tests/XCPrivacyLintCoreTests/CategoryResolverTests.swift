// CategoryResolverTests.swift: sanity tests for the bundled symbols.yaml.
//
// The fixture under test is Resources/symbols.yaml (loaded via Bundle.module
// from the XCPrivacyLintCore target). These tests assert that:
//   1. The YAML parses without errors.
//   2. All five currently-published Apple categories are present.
//   3. Known-canonical symbol lookups resolve correctly.
//
// When Apple announces a new category, add an assertion here that the new
// category is recognized, the test going green confirms the YAML is in sync
// with the published list.

import XCTest
@testable import XCPrivacyLintCore

final class CategoryResolverTests: XCTestCase {

    func testYAMLParsesCleanly() throws {
        _ = try CategoryResolver()
    }

    // `objectForKey:` is NSUserDefaults' and also NSDictionary's and NSCache's.
    // A binary that only uses NSCache was told it was missing the UserDefaults
    // declaration, as a hard error. Without the class it is now a warning.
    func testASelectorWhoseClassIsNotReferencedIsOnlyAWarning() throws {
        let resolver = try CategoryResolver()
        func report(classes: [String]) -> LintReport {
            let refs = MachOSymbolReferences(
                importedSymbols: Set(classes.map { ImportedSymbol(name: "OBJC_CLASS_$_\($0)") }),
                objcSelectors: ["objectForKey:", "setObject:forKey:"],
                architectures: ["arm64"])
            return Differ.report(target: "t", manifestPath: nil, needed: resolver.resolve(refs),
                                 declared: .empty, resolver: resolver, strict: false)
        }
        let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"

        let cacheOnly = report(classes: ["NSCache", "NSDictionary"])
        let soft = try XCTUnwrap(cacheOnly.findings.first { $0.category == userDefaults })
        XCTAssertEqual(soft.severity, .warning)
        XCTAssertTrue(soft.message.hasPrefix("Possibly missing declaration"), soft.message)
        XCTAssertEqual(cacheOnly.exitCode, 1)

        let defaults = report(classes: ["NSCache", "NSUserDefaults"])
        XCTAssertEqual(defaults.findings.first { $0.category == userDefaults }?.severity, .error)
        XCTAssertEqual(defaults.exitCode, 2)
    }

    func testAllPublishedCategoriesPresent() throws {
        let resolver = try CategoryResolver()
        let published: Set<APICategory> = [
            APICategory("NSPrivacyAccessedAPICategoryFileTimestamp"),
            APICategory("NSPrivacyAccessedAPICategorySystemBootTime"),
            APICategory("NSPrivacyAccessedAPICategoryDiskSpace"),
            APICategory("NSPrivacyAccessedAPICategoryActiveKeyboards"),
            APICategory("NSPrivacyAccessedAPICategoryUserDefaults")
        ]
        XCTAssertEqual(resolver.knownCategories, published,
                       "symbols.yaml diverged from Apple's published category list")
    }

    func testFileTimestampSymbolResolves() throws {
        let resolver = try CategoryResolver()
        XCTAssertEqual(
            resolver.category(forSymbol: "getattrlist"),
            APICategory("NSPrivacyAccessedAPICategoryFileTimestamp")
        )
    }

    func testSystemUptimeMethodResolves() throws {
        let resolver = try CategoryResolver()
        XCTAssertEqual(
            resolver.category(forObjCClass: "NSProcessInfo", method: "systemUptime"),
            APICategory("NSPrivacyAccessedAPICategorySystemBootTime")
        )
    }

    func testValidReasonsForSystemBootTime() throws {
        let resolver = try CategoryResolver()
        let valid = resolver.validReasons(for: APICategory("NSPrivacyAccessedAPICategorySystemBootTime"))
        XCTAssertTrue(valid.contains("35F9.1"))
        XCTAssertTrue(valid.contains("3D61.1"))
    }

    func testUnknownSymbolReturnsNil() throws {
        let resolver = try CategoryResolver()
        XCTAssertNil(resolver.category(forSymbol: "definitely_not_a_required_reason_symbol"))
    }

    /// Pins every category's reason codes to Apple's published list.
    ///
    /// The pre-existing coverage only asserted `contains`, so `8FFB.1` — a
    /// SystemBootTime reason — sat in FileTimestamp's list undetected. Because
    /// `validReasons` also backs the invalid-reason-code check, that made the
    /// linter accept a FileTimestamp/8FFB.1 manifest App Store Connect rejects.
    /// Exact-set assertions are what catch that class of error; keep them exact.
    ///
    /// Source: https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
    func testReasonCodesMatchApplesPublishedListExactly() throws {
        let resolver = try CategoryResolver()
        let expected: [String: Set<String>] = [
            "NSPrivacyAccessedAPICategoryFileTimestamp":   ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime":  ["35F9.1", "8FFB.1", "3D61.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace":       ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
            "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
            "NSPrivacyAccessedAPICategoryUserDefaults":    ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"]
        ]

        for (category, reasons) in expected {
            XCTAssertEqual(
                resolver.validReasons(for: APICategory(category)),
                reasons,
                "Reason codes for \(category) drifted from Apple's published list"
            )
        }
    }

    /// 8FFB.1 belongs to SystemBootTime only. Declaring it under FileTimestamp
    /// is rejected by App Store Connect, so the linter must not accept it.
    func testBootTimeReasonIsNotValidForFileTimestamp() throws {
        let resolver = try CategoryResolver()
        XCTAssertFalse(
            resolver.validReasons(for: APICategory("NSPrivacyAccessedAPICategoryFileTimestamp")).contains("8FFB.1"),
            "8FFB.1 is a SystemBootTime reason and must not validate under FileTimestamp"
        )
    }
}
