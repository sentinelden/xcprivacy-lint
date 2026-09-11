// MachOReaderTests.swift — the reader is the foundation of every finding, so
// these tests pin its behaviour against a real compiled binary and against
// `nm`, which is the ground truth users will compare us to.

import XCTest
@testable import XCPrivacyLintCore

final class MachOReaderTests: XCTestCase {

    func testExtractsImportedSymbolsFromRealBinary() throws {
        try XCTSkipUnless(Fixture.clangAvailable, "clang not available")
        let app = try Fixture.makeApp(manifest: nil)

        let refs = try MachOReader(path: app.binaryPath).parse()
        let names = Set(refs.importedSymbols.map(\.name))

        // The probe calls all three; each must survive the parse.
        XCTAssertTrue(names.contains("stat"), "expected `stat` among imports, got \(names.sorted())")
        XCTAssertTrue(names.contains("statfs"))
        XCTAssertTrue(names.contains("getattrlist"))
        XCTAssertFalse(refs.architectures.isEmpty)
    }

    /// Mach-O prefixes every C symbol with one underscore. We strip exactly
    /// that one — never more. `___stack_chk_fail` on disk is the source-level
    /// `__stack_chk_fail`, a reserved-namespace symbol that really does begin
    /// with two underscores; stripping greedily would corrupt it.
    func testStripsExactlyOneLeadingUnderscore() throws {
        try XCTSkipUnless(Fixture.clangAvailable, "clang not available")
        let app = try Fixture.makeApp(manifest: nil)

        let names = Set(try MachOReader(path: app.binaryPath).parse().importedSymbols.map(\.name))

        // Single-underscore symbol: fully unprefixed.
        XCTAssertTrue(names.contains("stat"))
        XCTAssertFalse(names.contains("_stat"))

        // Double-underscore symbol: keeps the one that belongs to the name.
        XCTAssertTrue(names.contains("__stack_chk_fail"),
                      "expected `__stack_chk_fail`, got \(names.filter { $0.contains("stack_chk") })")
        XCTAssertFalse(names.contains("___stack_chk_fail"))
    }

    func testExcludesLinkerInternalSymbols() throws {
        try XCTSkipUnless(Fixture.clangAvailable, "clang not available")
        let app = try Fixture.makeApp(manifest: nil)

        let refs = try MachOReader(path: app.binaryPath).parse()
        XCTAssertFalse(refs.importedSymbols.contains { $0.name == "dyld_stub_binder" },
                       "dyld_stub_binder describes linkage, not a call the program makes")
    }

    /// The strongest signal available: agree with the tool users already trust.
    func testMatchesNmOnASystemBinary() throws {
        let target = "/bin/ls"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: target))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/nm"))

        let ours = Set(try MachOReader(path: target).parse().importedSymbols.map(\.name))

        // `nm -u` prints undefined symbols per architecture; union them and
        // strip the underscore to get a comparable set.
        let nm = Process()
        nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        nm.arguments = ["-u", target]
        let pipe = Pipe()
        nm.standardOutput = pipe
        nm.standardError = Pipe()
        try nm.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nm.waitUntilExit()

        let expected = Set(
            output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("_") }
                .map { String($0.dropFirst()) }
        )
        try XCTSkipIf(expected.isEmpty, "nm produced no undefined symbols to compare against")

        XCTAssertTrue(expected.subtracting(ours).isEmpty,
                      "symbols nm found that we missed: \(expected.subtracting(ours).sorted())")
    }

    func testRejectsNonMachOInput() throws {
        let path = NSTemporaryDirectory() + "/not-a-binary-\(UUID().uuidString).txt"
        try "this is plainly not a Mach-O image".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try MachOReader(path: path).parse()) { error in
            guard case LinterError.unsupportedMachOFormat = error else {
                return XCTFail("expected .unsupportedMachOFormat, got \(error)")
            }
        }
    }

    func testReportsUnreadableFile() {
        XCTAssertThrowsError(try MachOReader(path: "/no/such/path/at/all").parse()) { error in
            guard case LinterError.binaryNotReadable = error else {
                return XCTFail("expected .binaryNotReadable, got \(error)")
            }
        }
    }

    /// A truncated header must error, never read out of bounds.
    func testHandlesTruncatedMachOHeader() throws {
        let path = NSTemporaryDirectory() + "/truncated-\(UUID().uuidString).bin"
        // Valid 64-bit magic, then nothing.
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertThrowsError(try MachOReader(path: path).parse())
    }
}
