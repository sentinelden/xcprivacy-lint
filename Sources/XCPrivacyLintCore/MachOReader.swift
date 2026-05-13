// MachOReader.swift — parse a Mach-O binary and emit the symbol references
// that matter for required-reason API detection.
//
// Supports thin Mach-O and fat (multi-arch) Mach-O. For fat binaries, the
// reader unions symbol sets across slices because the privacy manifest is
// per-bundle, not per-architecture.
//
// Three classes of reference we care about:
//   1. Imported C/POSIX symbols (LC_DYLD_INFO_ONLY's lazy_bind table) —
//      catches things like `getattrlist`, `statvfs`, `mach_absolute_time`.
//   2. Imported Swift symbols (same lazy-bind table; mangled names start
//      with `_$s`) — catches `ProcessInfo.systemUptime` etc. via the
//      mangled-name suffix.
//   3. Objective-C class + method references (__objc_classlist /
//      __objc_methname sections) — catches `NSUserDefaults`, etc.
//
// See DESIGN.md §5.2.

import Foundation

public struct ImportedSymbol: Sendable, Hashable {
    public let name: String           // raw mangled name (Swift) or C symbol
    public let section: String?       // __TEXT, __DATA, etc. (best-effort)
}

public struct ObjCMethodReference: Sendable, Hashable {
    public let className: String
    public let methodName: String     // selector
}

public struct MachOSymbolReferences: Sendable {
    public let importedSymbols: Set<ImportedSymbol>
    public let objcMethods: Set<ObjCMethodReference>
}

public struct MachOReader {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Parse the binary and emit the union of imported symbols across all
    /// slices.
    ///
    /// TODO(v0.1): implement via either:
    ///   (a) shelling to `nm -gU --no-demangle` and parsing the output, or
    ///   (b) raw Mach-O parsing using Foundation's `MemoryMap` + the
    ///       mach-o.h structures.
    ///
    /// (a) is faster to ship and reliable; (b) is the long-term answer for
    /// strict reproducibility and offline distribution. Ship (a) first.
    public func parse() throws -> MachOSymbolReferences {
        // Placeholder. The real implementation lives in `parseLazyBindTable`
        // and `parseObjCClassList` below, both currently stubs.
        return MachOSymbolReferences(
            importedSymbols: [],
            objcMethods: []
        )
    }

    // MARK: - Stubs for the v0.1 implementation

    /// Walk the LC_DYLD_INFO_ONLY lazy-bind opcodes and yield each external
    /// symbol the binary imports. This is the canonical source for "what
    /// dynamic symbols does this binary actually reference."
    ///
    /// Reference: <https://opensource.apple.com/source/dyld/dyld-852.2/include/mach-o/loader.h>
    private func parseLazyBindTable() throws -> [ImportedSymbol] {
        // TODO(v0.1): memory-map the binary, find LC_DYLD_INFO_ONLY (cmd ==
        // 0x80000022), seek to bind_off, run the bind-opcode interpreter
        // accumulating BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM strings.
        // For fat binaries, iterate FAT_MAGIC slices first.
        return []
    }

    /// Walk __objc_classlist + __objc_classname + __objc_methname and yield
    /// (class, method) pairs the binary references.
    ///
    /// Reference: <https://en.wikipedia.org/wiki/Objective-C#Class_metadata>
    private func parseObjCClassList() throws -> [ObjCMethodReference] {
        // TODO(v0.1): walk the __DATA segment's __objc_* sections.
        return []
    }
}
