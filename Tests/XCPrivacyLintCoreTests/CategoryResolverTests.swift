// CategoryResolverTests.swift — sanity tests for the bundled symbols.yaml.
//
// The fixture under test is Resources/symbols.yaml (loaded via Bundle.module
// from the XCPrivacyLintCore target). These tests assert that:
//   1. The YAML parses without errors.
//   2. All five currently-published Apple categories are present.
//   3. Known-canonical symbol lookups resolve correctly.
//
// When Apple announces a new category, add an assertion here that the new
// category is recognized — the test going green confirms the YAML is in sync
// with the published list.

import XCTest
@testable import XCPrivacyLintCore

final class CategoryResolverTests: XCTestCase {

    func testYAMLParsesCleanly() throws {
        _ = try CategoryResolver()
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
}
