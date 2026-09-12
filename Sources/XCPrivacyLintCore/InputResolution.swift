// InputResolution.swift: turn a CLI input (.app / .ipa / .xcframework /
// .xcarchive, or explicit --binary + --manifest paths) into one or more
// `BinaryAnalysisJob` instances the Linter can consume.
//
// Each input format has its own walking convention; the detector is a single
// switch on extension/structure. See DESIGN.md §5.1.

import Foundation

public enum InputResolutionError: Error, LocalizedError {
    case neitherTargetNorPathProvided
    case targetDoesNotExist(path: String)
    case unrecognizedInputFormat(path: String)
    case binaryNotFound(in: String)
    case manifestNotFound(in: String)
    case ipaExtractionFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .neitherTargetNorPathProvided:
            return "either pass a <target> path or both --binary and --manifest"
        case .targetDoesNotExist(let p):
            return "target path does not exist: \(p)"
        case .unrecognizedInputFormat(let p):
            return "could not determine input format for: \(p). Supported: .app, .ipa, .xcframework, .xcarchive"
        case .binaryNotFound(let p):
            return "could not locate the executable binary inside \(p)"
        case .manifestNotFound(let p):
            return "PrivacyInfo.xcprivacy not found inside \(p), declare or pass --manifest"
        case .ipaExtractionFailed(let e):
            return "failed to unpack .ipa: \(e.localizedDescription)"
        }
    }
}

public struct BinaryAnalysisJob: Sendable {
    public let binaryPath: String
    public let manifestPath: String?

    public init(binaryPath: String, manifestPath: String?) {
        self.binaryPath = binaryPath
        self.manifestPath = manifestPath
    }
}

/// Resolve the CLI's input arguments into one or more jobs.
///
/// One job per binary slice. A single .app produces one job; a .xcframework
/// with iOS + iOS Simulator slices produces two; a fat Mach-O is left as one
/// job (the slices share a manifest).
public func resolveJobs(
    target: String?,
    manifest: String?,
    binary: String?
) throws -> [BinaryAnalysisJob] {

    // Path 1: explicit --binary + --manifest, no auto-detect.
    if let binary, !binary.isEmpty {
        return [BinaryAnalysisJob(binaryPath: binary, manifestPath: manifest)]
    }

    guard let target, !target.isEmpty else {
        throw InputResolutionError.neitherTargetNorPathProvided
    }

    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
        throw InputResolutionError.targetDoesNotExist(path: target)
    }

    let ext = (target as NSString).pathExtension.lowercased()
    switch ext {
    case "app":
        return [try resolveApp(at: target)]
    case "ipa":
        return [try resolveIPA(at: target)]
    case "xcframework":
        return try resolveXCFramework(at: target)
    case "xcarchive":
        return [try resolveXCArchive(at: target)]
    default:
        // Bare binary? Accept it if it is a regular file that actually starts
        // with Mach-O magic, checking the bytes rather than trusting the
        // extension, since build products are routinely renamed.
        if !isDir.boolValue, isMachO(atPath: target) {
            return [BinaryAnalysisJob(binaryPath: target, manifestPath: manifest)]
        }
        throw InputResolutionError.unrecognizedInputFormat(path: target)
    }
}

// MARK: - Mach-O detection

/// True when the file begins with a thin or fat Mach-O magic number.
func isMachO(atPath path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
    let be = UInt32(head[head.startIndex]) << 24 | UInt32(head[head.startIndex + 1]) << 16
           | UInt32(head[head.startIndex + 2]) << 8 | UInt32(head[head.startIndex + 3])
    switch be {
    case 0xcafe_babe, 0xcafe_babf,          // fat, fat64
         0xfeed_face, 0xfeed_facf,          // thin 32/64, big-endian order
         0xcefa_edfe, 0xcffa_edfe:          // thin 32/64, byte-swapped
        return true
    default:
        return false
    }
}

// MARK: - .ipa

/// An .ipa is a zip whose payload is `Payload/<App>.app`. Unpack to a
/// temporary directory and hand off to the .app walker.
///
/// The extraction directory is deliberately not cleaned up during the run: the
/// job holds paths into it, and the Linter reads them lazily. The OS reclaims
/// NSTemporaryDirectory on its own schedule, which is the right owner for a
/// short-lived CLI.
private func resolveIPA(at path: String) throws -> BinaryAnalysisJob {
    let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xcprivacy-lint-ipa-\(UUID().uuidString)")

    do {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", path, "-d", destination.path]
        unzip.standardOutput = Pipe()
        unzip.standardError = Pipe()
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw InputResolutionError.ipaExtractionFailed(
                underlying: NSError(domain: "unzip", code: Int(unzip.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: "unzip exited \(unzip.terminationStatus)"])
            )
        }
    } catch let error as InputResolutionError {
        throw error
    } catch {
        throw InputResolutionError.ipaExtractionFailed(underlying: error)
    }

    let payload = destination.appendingPathComponent("Payload")
    let apps = (try? FileManager.default.contentsOfDirectory(atPath: payload.path))?
        .filter { $0.hasSuffix(".app") }
        .sorted() ?? []
    guard let app = apps.first else {
        throw InputResolutionError.binaryNotFound(in: path)
    }
    return try resolveApp(at: payload.appendingPathComponent(app).path)
}

// MARK: - .xcarchive

/// An .xcarchive holds the app at `Products/Applications/<App>.app`.
private func resolveXCArchive(at path: String) throws -> BinaryAnalysisJob {
    let applications = (path as NSString)
        .appendingPathComponent("Products/Applications")
    let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications))?
        .filter { $0.hasSuffix(".app") }
        .sorted() ?? []
    guard let app = apps.first else {
        throw InputResolutionError.binaryNotFound(in: path)
    }
    return try resolveApp(at: (applications as NSString).appendingPathComponent(app))
}

// MARK: - .xcframework

/// An .xcframework wraps one build per platform, listed in its Info.plist
/// under `AvailableLibraries`. Each entry names a `LibraryIdentifier`
/// subdirectory and a `LibraryPath` inside it.
///
/// Returns one job per slice: a framework can legitimately ship a different
/// privacy manifest per platform, and a finding in the iOS slice must not be
/// masked by a clean simulator slice.
private func resolveXCFramework(at path: String) throws -> [BinaryAnalysisJob] {
    let infoPath = (path as NSString).appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
          let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
          let libraries = plist["AvailableLibraries"] as? [[String: Any]],
          !libraries.isEmpty
    else {
        throw InputResolutionError.unrecognizedInputFormat(path: path)
    }

    var jobs: [BinaryAnalysisJob] = []
    for library in libraries {
        guard let identifier = library["LibraryIdentifier"] as? String,
              let libraryPath = library["LibraryPath"] as? String
        else { continue }

        let slice = (path as NSString)
            .appendingPathComponent(identifier)
        let product = (slice as NSString).appendingPathComponent(libraryPath)

        // LibraryPath is either `Foo.framework` or a static `libFoo.a`.
        if libraryPath.hasSuffix(".framework") {
            let name = (libraryPath as NSString).deletingPathExtension
            let binary = (product as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: binary) else { continue }

            // A framework's manifest sits at the bundle root on macOS-style
            // layouts and under Resources/ on iOS-style ones. Check both.
            let candidates = [
                (product as NSString).appendingPathComponent("PrivacyInfo.xcprivacy"),
                (product as NSString).appendingPathComponent("Resources/PrivacyInfo.xcprivacy")
            ]
            let manifest = candidates.first { FileManager.default.fileExists(atPath: $0) }
            jobs.append(BinaryAnalysisJob(binaryPath: binary, manifestPath: manifest))
        } else {
            guard FileManager.default.fileExists(atPath: product) else { continue }
            let manifest = (slice as NSString).appendingPathComponent("PrivacyInfo.xcprivacy")
            jobs.append(BinaryAnalysisJob(
                binaryPath: product,
                manifestPath: FileManager.default.fileExists(atPath: manifest) ? manifest : nil
            ))
        }
    }

    guard !jobs.isEmpty else { throw InputResolutionError.binaryNotFound(in: path) }
    return jobs
}

// MARK: - .app walking

private func resolveApp(at path: String) throws -> BinaryAnalysisJob {
    // An .app bundle has its executable named in Info.plist under
    // CFBundleExecutable, sitting at <App>.app/<CFBundleExecutable>.
    // PrivacyInfo.xcprivacy, if present, sits at <App>.app/PrivacyInfo.xcprivacy.

    let infoPlist = (path as NSString).appendingPathComponent("Info.plist")
    let plistData = (try? Data(contentsOf: URL(fileURLWithPath: infoPlist))) ?? Data()
    let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
    let exeName = plist?["CFBundleExecutable"] as? String

    let binaryPath: String
    if let exeName, !exeName.isEmpty {
        binaryPath = (path as NSString).appendingPathComponent(exeName)
    } else {
        // No CFBundleExecutable (a malformed or hand-assembled bundle). Fall
        // back to the first file in the bundle root that is actually a Mach-O
        // image, rather than guessing from the bundle name.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted() ?? []
        let found = contents
            .map { (path as NSString).appendingPathComponent($0) }
            .first { isMachO(atPath: $0) }
        guard let found else { throw InputResolutionError.binaryNotFound(in: path) }
        binaryPath = found
    }

    guard FileManager.default.fileExists(atPath: binaryPath) else {
        throw InputResolutionError.binaryNotFound(in: path)
    }

    let manifestPath = (path as NSString).appendingPathComponent("PrivacyInfo.xcprivacy")
    let resolvedManifest: String? = FileManager.default.fileExists(atPath: manifestPath) ? manifestPath : nil

    return BinaryAnalysisJob(binaryPath: binaryPath, manifestPath: resolvedManifest)
}
