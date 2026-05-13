// InputResolution.swift — turn a CLI input (.app / .ipa / .xcframework /
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
            return "PrivacyInfo.xcprivacy not found inside \(p) — declare or pass --manifest"
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

    // Auto-detect by extension. TODO(v0.2): also detect by magic bytes for
    // path-renamed inputs.
    let ext = (target as NSString).pathExtension.lowercased()
    switch ext {
    case "app":
        return [try resolveApp(at: target)]
    case "ipa":
        // TODO(v0.2): unzip Payload/<App>.app into a temp dir, then resolveApp.
        throw InputResolutionError.unrecognizedInputFormat(path: target)
    case "xcframework":
        // TODO(v0.2): enumerate Info.plist's AvailableLibraries, return one
        // job per slice.
        throw InputResolutionError.unrecognizedInputFormat(path: target)
    case "xcarchive":
        // TODO(v0.2): walk Products/Applications/<App>.app then resolveApp.
        throw InputResolutionError.unrecognizedInputFormat(path: target)
    default:
        // Bare binary? Try to use it directly if it's a regular file.
        if !isDir.boolValue {
            return [BinaryAnalysisJob(binaryPath: target, manifestPath: manifest)]
        }
        throw InputResolutionError.unrecognizedInputFormat(path: target)
    }
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
        // Fallback: assume single Mach-O file in the bundle root.
        // TODO(v0.1): be smarter — walk and detect Mach-O magic bytes.
        let fallback = (path as NSString).appendingPathComponent((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))
        binaryPath = fallback
    }

    guard FileManager.default.fileExists(atPath: binaryPath) else {
        throw InputResolutionError.binaryNotFound(in: path)
    }

    let manifestPath = (path as NSString).appendingPathComponent("PrivacyInfo.xcprivacy")
    let resolvedManifest: String? = FileManager.default.fileExists(atPath: manifestPath) ? manifestPath : nil

    return BinaryAnalysisJob(binaryPath: binaryPath, manifestPath: resolvedManifest)
}
