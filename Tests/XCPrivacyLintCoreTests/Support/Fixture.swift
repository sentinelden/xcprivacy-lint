// Fixture.swift: build a real .app bundle at test time.
//
// Binary-analysis tests need a real Mach-O to be worth anything, and checking
// compiled binaries into the repo makes them unauditable and stale. So we
// compile a small probe with clang instead: the test then asserts against a
// binary whose source is visible three lines away.
//
// Tests that need a fixture skip themselves when clang is unavailable rather
// than failing, so the suite stays green on a machine without command-line
// tools.

import Foundation
import XCTest

enum Fixture {

    struct Bundle {
        let appPath: String
        let binaryPath: String
        let manifestPath: String
    }

    /// Source for the probe binary. Each call is chosen to sit in a different
    /// required-reason category so a single fixture exercises several rules.
    static let probeSource = """
    #include <sys/stat.h>
    #include <sys/attr.h>
    #include <sys/mount.h>
    #include <unistd.h>
    #include <stdio.h>
    int main(void) {
        struct stat st;
        stat("/tmp", &st);                             // FileTimestamp
        struct statfs fs;
        statfs("/tmp", &fs);                           // DiskSpace
        struct attrlist al = {0};
        char buf[512];
        getattrlist("/tmp", &al, buf, sizeof buf, 0);  // FileTimestamp
        printf("%lld\\n", (long long)st.st_mtime);
        return 0;
    }
    """

    static var clangAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/clang")
    }

    /// Compile the probe into a minimal .app with the given manifest body.
    /// Pass `manifest: nil` to omit PrivacyInfo.xcprivacy entirely.
    static func makeApp(manifest: String?, file: StaticString = #filePath, line: UInt = #line) throws -> Bundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcprivacy-lint-tests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("probe.c")
        try probeSource.write(to: source, atomically: true, encoding: .utf8)

        let binary = app.appendingPathComponent("Fixture")
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-o", binary.path, source.path]
        clang.standardOutput = Pipe()
        clang.standardError = Pipe()
        try clang.run()
        clang.waitUntilExit()
        guard clang.terminationStatus == 0 else {
            throw XCTSkip("clang failed to build the fixture binary")
        }

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleExecutable</key><string>Fixture</string>
          <key>CFBundleIdentifier</key><string>com.example.fixture</string>
        </dict></plist>
        """
        try infoPlist.write(to: app.appendingPathComponent("Info.plist"),
                            atomically: true, encoding: .utf8)

        let manifestURL = app.appendingPathComponent("PrivacyInfo.xcprivacy")
        if let manifest {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        }

        return Bundle(appPath: app.path,
                      binaryPath: binary.path,
                      manifestPath: manifestURL.path)
    }

    /// Wrap a list of <dict> entries in a complete manifest plist.
    static func manifest(accessedAPIs: [(category: String, reasons: [String])]) -> String {
        let entries = accessedAPIs.map { api in
            let reasons = api.reasons.map { "<string>\($0)</string>" }.joined()
            return """
              <dict>
                <key>NSPrivacyAccessedAPIType</key><string>\(api.category)</string>
                <key>NSPrivacyAccessedAPITypeReasons</key><array>\(reasons)</array>
              </dict>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>NSPrivacyAccessedAPITypes</key>
          <array>
        \(entries)
          </array>
        </dict></plist>
        """
    }
}
