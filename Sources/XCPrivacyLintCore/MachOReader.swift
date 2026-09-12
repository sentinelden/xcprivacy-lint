// MachOReader.swift: parse a Mach-O binary and emit the symbol references
// that matter for required-reason API detection.
//
// Supports thin Mach-O and fat (multi-arch) Mach-O, 32- and 64-bit, in both
// endiannesses. For fat binaries the reader unions symbol sets across slices,
// because the privacy manifest is per-bundle, not per-architecture.
//
// Two classes of reference we care about:
//
//   1. Imported symbols, the undefined external entries in LC_SYMTAB. These
//      are exactly the functions the binary calls but does not define, which
//      is the definition of "uses this API": `getattrlist`, `statfs`,
//      `mach_absolute_time`, and the mangled Swift thunks that wrap them.
//
//   2. Objective-C selector references, the C strings in the __objc_methname
//      section, which the runtime uses to build selector tables. Any selector
//      the binary sends appears here.
//
// A note on why LC_SYMTAB rather than the dyld bind opcodes: both answer the
// same question, but the symbol table is a flat, position-independent array
// with an explicit count, while the bind table is a bytecode stream whose
// encoding has changed three times (LC_DYLD_INFO, LC_DYLD_INFO_ONLY, and the
// chained fixups of LC_DYLD_CHAINED_FIXUPS). The symbol table is present and
// stable in every one of those eras, including binaries built with chained
// fixups where the classic bind table is absent entirely. We trade a small
// amount of precision, the symbol table does not tell us *where* a symbol is
// referenced from, for correctness across the whole range of inputs people
// will actually feed us.
//
// See DESIGN.md §5.2.

import Foundation

public struct ImportedSymbol: Sendable, Hashable {
    /// Symbol name with the Mach-O leading underscore stripped. Swift symbols
    /// remain mangled (`$s10Foundation...`); matching against mangled names is
    /// the caller's problem.
    public let name: String
    /// Best-effort origin. The symbol table records the library ordinal rather
    /// than a section, so this is the dylib name when we can recover it.
    public let library: String?

    public init(name: String, library: String? = nil) {
        self.name = name
        self.library = library
    }
}

public struct MachOSymbolReferences: Sendable {
    /// Undefined external symbols, the binary's dynamic import surface.
    public let importedSymbols: Set<ImportedSymbol>
    /// Objective-C selectors referenced anywhere in the binary.
    public let objcSelectors: Set<String>
    /// Architectures actually parsed, e.g. ["arm64", "x86_64"]. Surfaced in
    /// verbose output so a user can tell when a fat binary was only partly
    /// understood.
    public let architectures: [String]

    public init(importedSymbols: Set<ImportedSymbol>,
                objcSelectors: Set<String>,
                architectures: [String]) {
        self.importedSymbols = importedSymbols
        self.objcSelectors = objcSelectors
        self.architectures = architectures
    }
}

public struct MachOReader {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Parse the binary and emit the union of references across all slices.
    ///
    /// - Throws: `LinterError.binaryNotReadable` if the file cannot be read,
    ///   `LinterError.unsupportedMachOFormat` if it is not a Mach-O image.
    public func parse() throws -> MachOSymbolReferences {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LinterError.binaryNotReadable(path: path)
        }

        var symbols: Set<ImportedSymbol> = []
        var selectors: Set<String> = []
        var arches: [String] = []

        for slice in try Self.slices(in: data) {
            let refs = try Self.parseSlice(data, at: slice.offset)
            symbols.formUnion(refs.importedSymbols)
            selectors.formUnion(refs.objcSelectors)
            arches.append(slice.architecture)
        }

        return MachOSymbolReferences(
            importedSymbols: symbols,
            objcSelectors: selectors,
            architectures: arches
        )
    }

    // MARK: - Slice discovery

    private struct Slice {
        let offset: Int
        let architecture: String
    }

    /// Return one entry per Mach-O image in the file. A thin binary yields a
    /// single slice at offset 0; a fat binary yields one per `fat_arch`.
    private static func slices(in data: Data) throws -> [Slice] {
        guard data.count >= 8 else { throw LinterError.unsupportedMachOFormat }

        // The fat header is always big-endian on disk, regardless of the
        // architectures it contains.
        let magic = data.readUInt32(at: 0, bigEndian: true)

        switch magic {
        case 0xcafe_babe, 0xcafe_babf:
            let is64 = (magic == 0xcafe_babf)
            let count = Int(data.readUInt32(at: 4, bigEndian: true))
            // A pathological header could claim millions of slices; cap the
            // read at what the file could physically hold.
            let entrySize = is64 ? 32 : 20
            guard count > 0, 8 + count * entrySize <= data.count else {
                throw LinterError.unsupportedMachOFormat
            }
            return (0..<count).map { i in
                let base = 8 + i * entrySize
                let cpuType = Int32(bitPattern: data.readUInt32(at: base, bigEndian: true))
                let cpuSubtype = Int32(bitPattern: data.readUInt32(at: base + 4, bigEndian: true))
                let offset = is64
                    ? Int(data.readUInt64(at: base + 8, bigEndian: true))
                    : Int(data.readUInt32(at: base + 8, bigEndian: true))
                return Slice(offset: offset,
                             architecture: architectureName(cpuType: cpuType, subtype: cpuSubtype))
            }

        case 0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe:
            // Thin image.
            //
            // `magic` above was read big-endian because a fat header is always
            // big-endian on disk. A thin header is not, so that value cannot be
            // reused to decide byte order here: for a little-endian image the
            // big-endian read yields 0xCFFAEDFE, which looks like the
            // byte-swapped case and inverts every field read after it. Read the
            // magic natively instead, exactly as parseSlice does.
            let native = data.readUInt32(at: 0, bigEndian: false)
            let swap: Bool
            switch native {
            case 0xfeed_face, 0xfeed_facf: swap = false
            case 0xcefa_edfe, 0xcffa_edfe: swap = true
            default: throw LinterError.unsupportedMachOFormat
            }
            let cpuType = Int32(bitPattern: data.readUInt32(at: 4, bigEndian: swap))
            let cpuSubtype = Int32(bitPattern: data.readUInt32(at: 8, bigEndian: swap))
            return [Slice(offset: 0,
                          architecture: architectureName(cpuType: cpuType, subtype: cpuSubtype))]

        default:
            throw LinterError.unsupportedMachOFormat
        }
    }

    // MARK: - Single-slice parsing

    private static func parseSlice(_ data: Data, at sliceOffset: Int) throws -> MachOSymbolReferences {
        guard sliceOffset + 32 <= data.count else {
            throw LinterError.unsupportedMachOFormat
        }

        let rawMagic = data.readUInt32(at: sliceOffset, bigEndian: false)
        let is64: Bool
        let swap: Bool
        switch rawMagic {
        case 0xfeed_facf: is64 = true;  swap = false
        case 0xfeed_face: is64 = false; swap = false
        case 0xcffa_edfe: is64 = true;  swap = true
        case 0xcefa_edfe: is64 = false; swap = true
        default: throw LinterError.unsupportedMachOFormat
        }

        let ncmds = Int(data.readUInt32(at: sliceOffset + 16, bigEndian: swap))
        let headerSize = is64 ? 32 : 28

        var symbols: Set<ImportedSymbol> = []
        var selectors: Set<String> = []

        // Walk the load commands once, handling the two we care about.
        var cursor = sliceOffset + headerSize
        for _ in 0..<ncmds {
            guard cursor + 8 <= data.count else { break }
            let cmd = data.readUInt32(at: cursor, bigEndian: swap)
            let cmdSize = Int(data.readUInt32(at: cursor + 4, bigEndian: swap))
            // A zero or negative cmdsize would spin this loop forever.
            guard cmdSize >= 8, cursor + cmdSize <= data.count else { break }

            switch cmd {
            case 0x2:   // LC_SYMTAB
                symbols.formUnion(
                    parseSymbolTable(data, command: cursor, sliceOffset: sliceOffset,
                                     is64: is64, swap: swap)
                )
            case 0x19:  // LC_SEGMENT_64
                selectors.formUnion(
                    parseSelectors(data, segment: cursor, sliceOffset: sliceOffset,
                                   is64: true, swap: swap)
                )
            case 0x1:   // LC_SEGMENT (32-bit)
                selectors.formUnion(
                    parseSelectors(data, segment: cursor, sliceOffset: sliceOffset,
                                   is64: false, swap: swap)
                )
            default:
                break
            }
            cursor += cmdSize
        }

        return MachOSymbolReferences(importedSymbols: symbols,
                                     objcSelectors: selectors,
                                     architectures: [])
    }

    /// Extract undefined external symbols from an LC_SYMTAB command.
    ///
    /// `symtab_command` is { cmd, cmdsize, symoff, nsyms, stroff, strsize },
    /// where symoff/stroff are offsets from the start of the *slice*, not the
    /// file: which matters for fat binaries.
    private static func parseSymbolTable(_ data: Data,
                                         command: Int,
                                         sliceOffset: Int,
                                         is64: Bool,
                                         swap: Bool) -> Set<ImportedSymbol> {
        let symOff = sliceOffset + Int(data.readUInt32(at: command + 8, bigEndian: swap))
        let nsyms = Int(data.readUInt32(at: command + 12, bigEndian: swap))
        let strOff = sliceOffset + Int(data.readUInt32(at: command + 16, bigEndian: swap))
        let strSize = Int(data.readUInt32(at: command + 20, bigEndian: swap))

        let entrySize = is64 ? 16 : 12
        guard nsyms > 0,
              symOff >= 0, strOff >= 0,
              symOff + nsyms * entrySize <= data.count,
              strOff + strSize <= data.count
        else { return [] }

        var result: Set<ImportedSymbol> = []
        result.reserveCapacity(min(nsyms, 4096))

        for i in 0..<nsyms {
            let entry = symOff + i * entrySize
            let strx = Int(data.readUInt32(at: entry, bigEndian: swap))
            let type = data[data.startIndex + entry + 4]

            // Skip debug symbols (N_STAB); they describe source, not linkage.
            guard type & 0xe0 == 0 else { continue }
            // Undefined (N_UNDF, type bits == 0) and external (N_EXT) means
            // "this binary calls it but does not define it", an import.
            guard type & 0x0e == 0x00, type & 0x01 != 0 else { continue }
            guard strx > 0, strOff + strx < strOff + strSize else { continue }

            guard let name = data.readCString(at: strOff + strx, limit: strOff + strSize),
                  !name.isEmpty else { continue }

            // Mach-O prefixes C symbols with an underscore; callers think in
            // terms of the source-level name.
            let stripped = name.hasPrefix("_") ? String(name.dropFirst()) : name
            guard !Self.linkerInternalSymbols.contains(stripped) else { continue }
            result.insert(ImportedSymbol(name: stripped, library: nil))
        }
        return result
    }

    /// Extract Objective-C selector strings from a segment's __objc_methname
    /// section, which is a run of NUL-terminated C strings.
    private static func parseSelectors(_ data: Data,
                                       segment: Int,
                                       sliceOffset: Int,
                                       is64: Bool,
                                       swap: Bool) -> Set<String> {
        // segment_command_64: cmd, cmdsize, segname[16], vmaddr, vmsize,
        // fileoff, filesize, maxprot, initprot, nsects, flags
        let nsectsOffset = is64 ? 64 : 48
        let sectionsStart = segment + (is64 ? 72 : 56)
        let sectionSize = is64 ? 80 : 68

        guard segment + nsectsOffset + 4 <= data.count else { return [] }
        let nsects = Int(data.readUInt32(at: segment + nsectsOffset, bigEndian: swap))
        guard nsects > 0, sectionsStart + nsects * sectionSize <= data.count else { return [] }

        var selectors: Set<String> = []

        for i in 0..<nsects {
            let sect = sectionsStart + i * sectionSize
            guard let sectName = data.readFixedString(at: sect, length: 16) else { continue }
            guard sectName == "__objc_methname" else { continue }

            // section_64: sectname[16], segname[16], addr, size, offset, ...
            let sizeField = sect + 32 + (is64 ? 8 : 4)
            let offsetField = sizeField + (is64 ? 8 : 4)
            let size = is64
                ? Int(data.readUInt64(at: sizeField, bigEndian: swap))
                : Int(data.readUInt32(at: sizeField, bigEndian: swap))
            let offset = sliceOffset + Int(data.readUInt32(at: offsetField, bigEndian: swap))

            guard size > 0, offset >= 0, offset + size <= data.count else { continue }
            selectors.formUnion(data.readCStringRun(from: offset, count: size))
        }

        return selectors
    }

    /// Symbols the static linker injects that describe linkage rather than a
    /// call the program makes. `nm -u` hides these; so do we, so that
    /// `--dump-symbols` output can be diffed against `nm` without noise.
    private static let linkerInternalSymbols: Set<String> = [
        "dyld_stub_binder",
        "__mh_execute_header",
        "__mh_dylib_header",
        "__mh_bundle_header",
    ]

    // MARK: - Architecture naming

    private static func architectureName(cpuType: Int32, subtype: Int32) -> String {
        // Only the subtypes we can meaningfully distinguish; anything else
        // falls back to the bare family name.
        switch cpuType {
        case 0x0100_000c: return (subtype & 0x00ff_ffff) == 2 ? "arm64e" : "arm64"
        case 0x0000_000c: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return "cpu(\(cpuType))"
        }
    }
}

// MARK: - Bounds-checked byte access
//
// Every read below is explicitly bounds-checked against the buffer. A privacy
// linter routinely gets pointed at binaries from untrusted sources, a build
// artifact from a vendor SDK, an .ipa pulled off a device, and a malformed
// header must produce an error, never an out-of-bounds read.

private extension Data {
    func readUInt32(at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        let bytes = (0..<4).map { UInt32(self[base + $0]) }
        return bigEndian
            ? (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
            : (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0]
    }

    func readUInt64(at offset: Int, bigEndian: Bool) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        let hi = UInt64(readUInt32(at: bigEndian ? offset : offset + 4, bigEndian: bigEndian))
        let lo = UInt64(readUInt32(at: bigEndian ? offset + 4 : offset, bigEndian: bigEndian))
        return (hi << 32) | lo
    }

    /// Read a NUL-terminated string starting at `offset`, stopping at `limit`.
    func readCString(at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < limit, limit <= count else { return nil }
        var end = offset
        while end < limit, self[startIndex + end] != 0 { end += 1 }
        guard end > offset else { return "" }
        return String(data: subdata(in: (startIndex + offset)..<(startIndex + end)), encoding: .utf8)
    }

    /// Read a fixed-width, possibly-unterminated field such as `sectname[16]`.
    func readFixedString(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        let slice = subdata(in: (startIndex + offset)..<(startIndex + offset + length))
        let trimmed = slice.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .utf8)
    }

    /// Split a region of packed NUL-terminated C strings into its components.
    func readCStringRun(from offset: Int, count byteCount: Int) -> [String] {
        guard offset >= 0, offset + byteCount <= count else { return [] }
        var results: [String] = []
        var cursor = offset
        let end = offset + byteCount
        while cursor < end {
            var stringEnd = cursor
            while stringEnd < end, self[startIndex + stringEnd] != 0 { stringEnd += 1 }
            if stringEnd > cursor,
               let s = String(data: subdata(in: (startIndex + cursor)..<(startIndex + stringEnd)),
                              encoding: .utf8) {
                results.append(s)
            }
            cursor = stringEnd + 1
        }
        return results
    }
}
