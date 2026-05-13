// CategoryResolver.swift — load the symbol→category map at startup and
// answer "which required-reason category, if any, does this symbol trigger?"
//
// The map ships as Resources/symbols.yaml (embedded into the binary at build
// time via SwiftPM's `.copy` resource directive). Loading is one-time;
// lookups are O(1) hashmap reads.
//
// See DESIGN.md §6 for the map format and contribution model.

import Foundation
import Yams

public struct APICategory: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct CategoryEntry: Sendable {
    public let category: APICategory
    public let validReasons: Set<String>
    public let notes: String?
}

public struct ResolvedCategory: Sendable, Hashable {
    public let category: APICategory
    public let trigger: FindingTrigger
    public let suggestedReasons: [String]
}

public final class CategoryResolver {
    private let symbolIndex: [String: APICategory]
    private let objcIndex: [String: [String: APICategory]]   // [class][method] = category
    private let entries: [APICategory: CategoryEntry]

    /// Load the embedded `symbols.yaml`.
    ///
    /// Pass `nil` (the default) to use the SwiftPM-generated resource
    /// bundle for this module; pass an explicit `Bundle` from a host app
    /// or test target when the default isn't reachable. Resolving
    /// `Bundle.module` inside the body (rather than as a default argument
    /// value) avoids the "static property 'module' is internal" build
    /// error when CategoryResolver is exposed as `public`.
    public init(bundle: Bundle? = nil) throws {
        let resolvedBundle = bundle ?? .module
        guard let url = resolvedBundle.url(forResource: "symbols", withExtension: "yaml") else {
            throw LinterError.malformedSymbolMap(
                underlying: NSError(domain: "xcprivacy-lint", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "symbols.yaml not found in bundle resources"])
            )
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let parsed = try YAMLDecoder().decode([RawEntry].self, from: yaml)

        var symbolIndex: [String: APICategory] = [:]
        var objcIndex: [String: [String: APICategory]] = [:]
        var entries: [APICategory: CategoryEntry] = [:]
        for raw in parsed {
            let cat = APICategory(raw.category)
            entries[cat] = CategoryEntry(
                category: cat,
                validReasons: Set(raw.valid_reasons),
                notes: raw.notes
            )
            for s in raw.symbols ?? [] {
                symbolIndex[s] = cat
            }
            for objc in raw.objc_methods ?? [] {
                var perClass = objcIndex[objc.class, default: [:]]
                for m in objc.methods {
                    perClass[m] = cat
                }
                objcIndex[objc.class] = perClass
            }
        }
        self.symbolIndex = symbolIndex
        self.objcIndex = objcIndex
        self.entries = entries
    }

    /// Look up by C / Swift symbol.
    public func category(forSymbol symbol: String) -> APICategory? {
        symbolIndex[symbol]
    }

    /// Look up by Objective-C class + selector.
    public func category(forObjCClass className: String, method: String) -> APICategory? {
        objcIndex[className]?[method]
    }

    /// Valid reason codes for a category, used when emitting "missing
    /// declaration; suggest reason X or Y" messages.
    public func validReasons(for category: APICategory) -> Set<String> {
        entries[category]?.validReasons ?? []
    }

    /// All categories known to the resolver — useful for sanity-checking
    /// the bundled symbols.yaml against Apple's published list.
    public var knownCategories: Set<APICategory> {
        Set(entries.keys)
    }

    // MARK: - YAML decoder shape

    private struct RawEntry: Decodable {
        let category: String
        let valid_reasons: [String]
        let symbols: [String]?
        let objc_methods: [RawObjC]?
        let notes: String?
    }
    private struct RawObjC: Decodable {
        let `class`: String
        let methods: [String]
    }
}
