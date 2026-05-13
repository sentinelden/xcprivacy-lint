// PrivacyManifestReader.swift — parse PrivacyInfo.xcprivacy via Foundation's
// PropertyListDecoder into a strongly-typed model.
//
// The plist is intentionally simple; we lean on PropertyListDecoder's schema
// validation by using `Decodable` structs rather than walking raw NSDictionary.

import Foundation

public struct PrivacyManifest: Sendable, Codable, Equatable {
    public var NSPrivacyTracking: Bool
    public var NSPrivacyTrackingDomains: [String]
    public var NSPrivacyCollectedDataTypes: [CollectedDataType]
    public var NSPrivacyAccessedAPITypes: [AccessedAPI]

    public static let empty = PrivacyManifest(
        NSPrivacyTracking: false,
        NSPrivacyTrackingDomains: [],
        NSPrivacyCollectedDataTypes: [],
        NSPrivacyAccessedAPITypes: []
    )
}

public struct CollectedDataType: Sendable, Codable, Equatable {
    public var NSPrivacyCollectedDataType: String
    public var NSPrivacyCollectedDataTypeLinked: Bool?
    public var NSPrivacyCollectedDataTypeTracking: Bool?
    public var NSPrivacyCollectedDataTypePurposes: [String]?
}

public struct AccessedAPI: Sendable, Codable, Equatable, Hashable {
    public var NSPrivacyAccessedAPIType: String
    public var NSPrivacyAccessedAPITypeReasons: [String]
}

public struct PrivacyManifestReader {
    public init() {}

    public func read(path: String) throws -> PrivacyManifest {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = PropertyListDecoder()

        // Decode tolerantly: an absent NSPrivacyAccessedAPITypes is legal
        // ("we don't touch any required-reason API"). The Decodable
        // implementations below default to empty arrays for missing keys.
        return try decoder.decode(PrivacyManifest.self, from: data)
    }
}

// MARK: - Default-empty decoding for optional top-level arrays

private struct OptionalArrayContainer<T: Decodable>: Decodable {
    let value: [T]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = (try? container.decode([T].self)) ?? []
    }
}

extension PrivacyManifest {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.NSPrivacyTracking = (try? container.decode(Bool.self, forKey: .NSPrivacyTracking)) ?? false
        self.NSPrivacyTrackingDomains = (try? container.decode([String].self, forKey: .NSPrivacyTrackingDomains)) ?? []
        self.NSPrivacyCollectedDataTypes = (try? container.decode([CollectedDataType].self, forKey: .NSPrivacyCollectedDataTypes)) ?? []
        self.NSPrivacyAccessedAPITypes = (try? container.decode([AccessedAPI].self, forKey: .NSPrivacyAccessedAPITypes)) ?? []
    }
    enum CodingKeys: String, CodingKey {
        case NSPrivacyTracking, NSPrivacyTrackingDomains
        case NSPrivacyCollectedDataTypes, NSPrivacyAccessedAPITypes
    }
}
