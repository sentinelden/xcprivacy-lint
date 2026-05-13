// PrivacyManifestReaderTests.swift — fixture-based tests for plist parsing.
//
// Writes a synthetic PrivacyInfo.xcprivacy to a temp file, parses it, asserts
// the decoded model matches. Catches breaking changes to PropertyListDecoder
// behavior and to the strongly-typed `PrivacyManifest` shape.

import XCTest
@testable import XCPrivacyLintCore

final class PrivacyManifestReaderTests: XCTestCase {

    func testEmptyManifest() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """
        let manifest = try parseTemp(plist)
        XCTAssertFalse(manifest.NSPrivacyTracking)
        XCTAssertTrue(manifest.NSPrivacyTrackingDomains.isEmpty)
        XCTAssertTrue(manifest.NSPrivacyCollectedDataTypes.isEmpty)
        XCTAssertTrue(manifest.NSPrivacyAccessedAPITypes.isEmpty)
    }

    func testTypicalSDKManifest() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>NSPrivacyTracking</key>
            <false/>
            <key>NSPrivacyTrackingDomains</key>
            <array/>
            <key>NSPrivacyCollectedDataTypes</key>
            <array/>
            <key>NSPrivacyAccessedAPITypes</key>
            <array>
                <dict>
                    <key>NSPrivacyAccessedAPIType</key>
                    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
                    <key>NSPrivacyAccessedAPITypeReasons</key>
                    <array><string>C617.1</string></array>
                </dict>
                <dict>
                    <key>NSPrivacyAccessedAPIType</key>
                    <string>NSPrivacyAccessedAPICategorySystemBootTime</string>
                    <key>NSPrivacyAccessedAPITypeReasons</key>
                    <array><string>35F9.1</string></array>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let manifest = try parseTemp(plist)
        XCTAssertFalse(manifest.NSPrivacyTracking)
        XCTAssertEqual(manifest.NSPrivacyAccessedAPITypes.count, 2)
        XCTAssertTrue(manifest.NSPrivacyAccessedAPITypes.contains {
            $0.NSPrivacyAccessedAPIType == "NSPrivacyAccessedAPICategorySystemBootTime"
                && $0.NSPrivacyAccessedAPITypeReasons.contains("35F9.1")
        })
    }

    func testBinaryPlistParses() throws {
        // PropertyListDecoder handles both XML and binary plist formats; this
        // test ensures the binary representation works too (Xcode often
        // converts manifests to binary in shipped builds).
        let original = PrivacyManifest(
            NSPrivacyTracking: false,
            NSPrivacyTrackingDomains: [],
            NSPrivacyCollectedDataTypes: [],
            NSPrivacyAccessedAPITypes: [
                AccessedAPI(
                    NSPrivacyAccessedAPIType: "NSPrivacyAccessedAPICategorySystemBootTime",
                    NSPrivacyAccessedAPITypeReasons: ["35F9.1"]
                )
            ]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(original)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PrivacyInfo.xcprivacy")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parsed = try PrivacyManifestReader().read(path: tmp.path)
        XCTAssertEqual(parsed.NSPrivacyAccessedAPITypes.first?.NSPrivacyAccessedAPIType,
                       "NSPrivacyAccessedAPICategorySystemBootTime")
    }

    // MARK: - Helpers

    private func parseTemp(_ xmlPlist: String) throws -> PrivacyManifest {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PrivacyInfo-\(UUID()).xcprivacy")
        try xmlPlist.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try PrivacyManifestReader().read(path: tmp.path)
    }
}
