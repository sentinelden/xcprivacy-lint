// Differ.swift — compare what the binary needs against what the manifest
// declares, and turn the difference into Findings.
//
// Four outcomes per category:
//
//   needed & !declared  -> .missingDeclaration  (error — App Store will reject)
//   !needed & declared  -> .overDeclared        (warning — harmless but sloppy,
//                                                and Apple has begun querying
//                                                declarations with no matching
//                                                API use)
//   declared with a reason code not valid for that category
//                       -> .invalidReasonCode   (error)
//   needed & declared   -> .successfulMatch     (info — shown under --verbose)
//
// The asymmetry in severity is deliberate. A missing declaration is a hard
// rejection with a multi-day turnaround. An over-declaration costs nothing at
// review time, so defaulting it to a warning keeps the tool usable in CI
// without teams disabling it. `--strict` escalates it for teams that want the
// manifest to be exactly right.

import Foundation

extension CategoryResolver {
    /// Map every reference the binary makes onto the required-reason
    /// categories it triggers.
    ///
    /// Returns one `ResolvedCategory` per (category, trigger) pair, so a
    /// category triggered by three different symbols yields three entries.
    /// The Differ collapses them for reporting but keeps them here so
    /// `--verbose` can show every piece of evidence.
    public func resolve(_ refs: MachOSymbolReferences) -> Set<ResolvedCategory> {
        var resolved: Set<ResolvedCategory> = []

        for symbol in refs.importedSymbols {
            guard let category = category(forSymbol: symbol.name) else { continue }
            resolved.insert(
                ResolvedCategory(
                    category: category,
                    trigger: FindingTrigger(kind: .symbol,
                                            name: symbol.name,
                                            section: symbol.library),
                    suggestedReasons: validReasons(for: category).sorted()
                )
            )
        }

        for selector in refs.objcSelectors {
            guard let hit = category(forSelector: selector) else { continue }
            resolved.insert(
                ResolvedCategory(
                    category: hit.category,
                    trigger: FindingTrigger(kind: .objcMethod,
                                            name: "\(hit.className).\(selector)",
                                            section: "__objc_methname"),
                    suggestedReasons: validReasons(for: hit.category).sorted()
                )
            )
        }

        return resolved
    }
}

/// Join a list the way prose does: "A", "A or B", "A, B or C".
/// Findings get read by people under deadline pressure; "A or B or C or D"
/// reads as noise where a list reads as a choice.
func oxfordJoin(_ items: [String], conjunction: String = "or") -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    case 2: return "\(items[0]) \(conjunction) \(items[1])"
    default:
        return items.dropLast().joined(separator: ", ") + " \(conjunction) " + items[items.count - 1]
    }
}

public enum Differ {

    public static func report(target: String,
                              manifestPath: String?,
                              needed: Set<ResolvedCategory>,
                              declared: PrivacyManifest,
                              resolver: CategoryResolver,
                              strict: Bool) -> LintReport {

        var findings: [Finding] = []

        // Collapse the evidence: one entry per category, keeping every trigger
        // so we can name a representative one and count the rest.
        var evidence: [APICategory: [ResolvedCategory]] = [:]
        for item in needed {
            evidence[item.category, default: []].append(item)
        }

        let declaredByType = Dictionary(
            declared.NSPrivacyAccessedAPITypes.map { ($0.NSPrivacyAccessedAPIType, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let declaredTypes = Set(declaredByType.keys)
        let neededTypes = Set(evidence.keys.map(\.rawValue))

        // ── Missing declarations ──────────────────────────────────────────
        for type in neededTypes.subtracting(declaredTypes).sorted() {
            let category = APICategory(type)
            let triggers = (evidence[category] ?? []).sorted { $0.trigger.name < $1.trigger.name }
            guard let primary = triggers.first else { continue }

            let others = triggers.count - 1
            let alsoVia = others > 0 ? " (and \(others) other reference\(others == 1 ? "" : "s"))" : ""
            let reasons = primary.suggestedReasons

            findings.append(
                Finding(
                    severity: .error,
                    category: type,
                    kind: .missingDeclaration,
                    trigger: primary.trigger,
                    suggestedReasons: reasons,
                    message: """
                        Missing required declaration: \(type).
                        Triggered by \(primary.trigger.kind == .symbol ? "symbol" : "selector") \
                        `\(primary.trigger.name)`\(alsoVia).
                        Add the category to your manifest with \
                        \(reasons.isEmpty ? "an appropriate reason" : "reason " + oxfordJoin(reasons)).
                        """
                )
            )
        }

        // ── Over-declarations ─────────────────────────────────────────────
        for type in declaredTypes.subtracting(neededTypes).sorted() {
            findings.append(
                Finding(
                    severity: strict ? .error : .warning,
                    category: type,
                    kind: .overDeclared,
                    trigger: nil,
                    suggestedReasons: [],
                    message: """
                        Declared but unused: \(type).
                        No symbol or selector in the binary maps to this category. \
                        Remove it, or verify the API is reached through a dependency \
                        this binary does not statically reference.
                        """
                )
            )
        }

        // ── Invalid reason codes ──────────────────────────────────────────
        for (type, entry) in declaredByType.sorted(by: { $0.key < $1.key }) {
            let valid = resolver.validReasons(for: APICategory(type))
            // An unknown category has no reason list to validate against;
            // skip rather than emit a false positive.
            guard !valid.isEmpty else { continue }

            let invalid = entry.NSPrivacyAccessedAPITypeReasons.filter { !valid.contains($0) }
            guard !invalid.isEmpty else { continue }

            findings.append(
                Finding(
                    severity: .error,
                    category: type,
                    kind: .invalidReasonCode,
                    trigger: nil,
                    suggestedReasons: valid.sorted(),
                    message: """
                        Invalid reason code\(invalid.count == 1 ? "" : "s") for \(type): \
                        \(invalid.sorted().joined(separator: ", ")).
                        Valid codes for this category are \(valid.sorted().joined(separator: ", ")).
                        """
                )
            )
        }

        // ── Successful matches (verbose only) ─────────────────────────────
        for type in neededTypes.intersection(declaredTypes).sorted() {
            let category = APICategory(type)
            let triggers = (evidence[category] ?? []).sorted { $0.trigger.name < $1.trigger.name }
            let declaredReasons = declaredByType[type]?.NSPrivacyAccessedAPITypeReasons ?? []

            findings.append(
                Finding(
                    severity: .info,
                    category: type,
                    kind: .successfulMatch,
                    trigger: triggers.first?.trigger,
                    suggestedReasons: declaredReasons,
                    message: """
                        \(type) — declared with reason\(declaredReasons.count == 1 ? "" : "s") \
                        \(declaredReasons.joined(separator: ", ")); \
                        matched \(triggers.count) reference\(triggers.count == 1 ? "" : "s") in the binary.
                        """
                )
            )
        }

        return LintReport(target: target, manifestPath: manifestPath, findings: findings)
    }
}
