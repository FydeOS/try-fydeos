import CZlib
import Foundation

public struct VMDKInfo: Equatable, Sendable {
    public var capacity: Int64
    public var grainBytes: Int64
    public var createType: String
    public var compressed: Bool
}

public struct VMDKError: Error, CustomStringConvertible, Equatable {
    public var description: String
    init(_ description: String) { self.description = description }
}

/// Converts the VMDK extents FydeOS publishes for VMware (monolithicSparse and streamOptimized)
/// into raw disk data, reading the extent strictly forward so it can come straight out of a container.
public enum VMDK {
    static let sector: Int64 = 512
    static let magic: UInt32 = 0x564d_444b
    static let flagCompressed: UInt32 = 1 << 16
    static let flagMarkers: UInt32 = 1 << 17
    static let maxGrainSectors: UInt64 = 1 << 20
    static let maxDescSectors: UInt64 = 1 << 11
    static let maxOverhead: UInt64 = 1 << 19

    struct Header {
        var flags: UInt32
        var capacity: UInt64
        var grainSize: UInt64
        var descOffset: UInt64
        var descSize: UInt64
        var numGTEsPerGT: UInt32
        var gdOffset: UInt64
        var overhead: UInt64
    }

    final class Input {
        let read: (UnsafeMutableRawBufferPointer) throws -> Int
        var pos: Int64 = 0
        private var scratch = [UInt8](repeating: 0, count: 1 << 20)

        init(_ read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int) { self.read = read }

        func readFull(_ buffer: UnsafeMutableRawBufferPointer) throws {
            var done = 0
            while done < buffer.count {
                let n = try read(UnsafeMutableRawBufferPointer(rebasing: buffer[done...]))
                if n <= 0 { throw VMDKError("truncated at byte \(pos)") }
                done += n
                pos += Int64(n)
            }
        }

        func readFull(_ bytes: inout [UInt8], _ range: Range<Int>) throws {
            try bytes.withUnsafeMutableBytes { try readFull(UnsafeMutableRawBufferPointer(rebasing: $0[range])) }
        }

        func skip(to offset: Int64) throws {
            guard offset >= pos else { throw VMDKError("data at byte \(offset) overlaps byte \(pos) already read") }
            while pos < offset {
                let want = Int(min(Int64(scratch.count), offset - pos))
                let n = try scratch.withUnsafeMutableBytes { try read(UnsafeMutableRawBufferPointer(rebasing: $0[..<want])) }
                if n <= 0 { throw VMDKError("truncated at byte \(pos)") }
                pos += Int64(n)
            }
        }
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) }
    }

    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * $1) }
    }

    static func createType(_ descriptor: ArraySlice<UInt8>) -> String {
        let text = String(decoding: descriptor, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #"^\s*createType\s*=\s*"([^"]*)""#, options: .anchorsMatchLines),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return "" }
        return String(text[r])
    }

    static func parseHeader(_ b: [UInt8]) throws -> Header {
        guard u32(b, 0) == magic else { throw VMDKError("not a VMDK sparse extent (bad magic)") }
        let h = Header(flags: u32(b, 8), capacity: u64(b, 12), grainSize: u64(b, 20), descOffset: u64(b, 28),
                       descSize: u64(b, 36), numGTEsPerGT: u32(b, 44), gdOffset: u64(b, 56), overhead: u64(b, 64))
        if h.grainSize == 0 || h.grainSize & (h.grainSize - 1) != 0 || h.grainSize > maxGrainSectors {
            throw VMDKError("grain size \(h.grainSize) sectors is invalid")
        }
        if h.capacity == 0 || h.capacity > UInt64(Int64.max) / UInt64(sector) {
            throw VMDKError("capacity \(h.capacity) sectors is invalid")
        }
        if h.numGTEsPerGT == 0 || h.grainSize.multipliedReportingOverflow(by: UInt64(h.numGTEsPerGT)).overflow {
            throw VMDKError("\(h.numGTEsPerGT) grain table entries per table is invalid")
        }
        if h.descSize > maxDescSectors { throw VMDKError("descriptor size \(h.descSize) sectors is invalid") }
        return h
    }

    /// Reads one extent through `read` (bytes read, 0 at the end) and calls `write` for every allocated
    /// grain, in file order, with its byte offset in the virtual disk. The buffer is valid until `write` returns.
    @discardableResult
    public static func decode(read: @escaping (UnsafeMutableRawBufferPointer) throws -> Int,
                              write: (Int64, UnsafeRawBufferPointer) throws -> Void) throws -> VMDKInfo {
        let input = Input(read)
        var head = [UInt8](repeating: 0, count: Int(sector))
        do { try input.readFull(&head, 0..<head.count) } catch let e as VMDKError { throw VMDKError("reading VMDK header: \(e)") }
        let h = try parseHeader(head)
        var info = VMDKInfo(capacity: Int64(h.capacity) * sector, grainBytes: Int64(h.grainSize) * sector, createType: "", compressed: false)
        switch h.flags & (flagCompressed | flagMarkers) {
        case flagCompressed | flagMarkers:
            info.compressed = true
            try decodeStream(input, h, &info, write)
        case 0:
            try decodeSparse(input, head, h, &info, write)
        default:
            throw VMDKError("unsupported VMDK flags 0x\(String(h.flags, radix: 16)) (need both or neither of compressed grains and markers)")
        }
        return info
    }

    /// Reads from a file descriptor, retrying on EINTR.
    public static func reader(fd: Int32) -> (UnsafeMutableRawBufferPointer) throws -> Int {
        { buffer in
            while true {
                let n = Darwin.read(fd, buffer.baseAddress, buffer.count)
                if n >= 0 { return n }
                if errno != EINTR { throw VMDKError("read: \(String(cString: strerror(errno)))") }
            }
        }
    }

    private static func decodeSparse(_ input: Input, _ head: [UInt8], _ h: Header, _ info: inout VMDKInfo,
                                     _ write: (Int64, UnsafeRawBufferPointer) throws -> Void) throws {
        guard h.overhead != 0, h.overhead <= maxOverhead else { throw VMDKError("overhead \(h.overhead) sectors is invalid") }
        let sec = UInt64(sector)
        var meta = [UInt8](repeating: 0, count: Int(h.overhead * sec))
        meta.replaceSubrange(0..<head.count, with: head)
        do { try input.readFull(&meta, head.count..<meta.count) } catch let e as VMDKError { throw VMDKError("reading VMDK metadata: \(e)") }
        if h.descOffset != 0, h.descOffset + h.descSize <= h.overhead {
            info.createType = createType(meta[Int(h.descOffset * sec)..<Int((h.descOffset + h.descSize) * sec)])
        }

        let perGT = UInt64(h.numGTEsPerGT)
        let gtCover = h.grainSize * perGT
        let gdEntries = (h.capacity + gtCover - 1) / gtCover
        let gtBytes = perGT * 4
        if h.gdOffset == 0 || h.gdOffset >= h.overhead || h.gdOffset * sec + gdEntries * 4 > h.overhead * sec {
            throw VMDKError("grain directory at sector \(h.gdOffset) lies outside the \(h.overhead)-sector overhead")
        }
        var grains: [(file: UInt64, lba: UInt64)] = []
        for i in 0..<gdEntries {
            let gt = UInt64(u32(meta, Int(h.gdOffset * sec + i * 4)))
            if gt == 0 { continue }
            if gt >= h.overhead || gt * sec + gtBytes > h.overhead * sec {
                throw VMDKError("grain table \(i) at sector \(gt) lies outside the \(h.overhead)-sector overhead")
            }
            for j in 0..<perGT {
                let g = UInt64(u32(meta, Int(gt * sec + j * 4)))
                if g == 0 { continue }
                let lba = (i * perGT + j) * h.grainSize
                if lba >= h.capacity { throw VMDKError("grain at sector \(g) maps beyond capacity (LBA \(lba))") }
                grains.append((g, lba))
            }
        }
        grains.sort { $0.file < $1.file }

        var buf = [UInt8](repeating: 0, count: Int(info.grainBytes))
        for g in grains {
            if g.file < h.overhead { throw VMDKError("grain at sector \(g.file) lies inside the \(h.overhead)-sector overhead") }
            let off = Int64(g.lba) * sector
            let n = Int(min(info.grainBytes, info.capacity - off))
            do {
                try input.skip(to: Int64(g.file) * sector)
                try input.readFull(&buf, 0..<n)
            } catch let e as VMDKError {
                throw VMDKError("grain at sector \(g.file): \(e)")
            }
            try buf.withUnsafeBytes { try write(off, UnsafeRawBufferPointer(rebasing: $0[..<n])) }
        }
    }

    private static func decodeStream(_ input: Input, _ h: Header, _ info: inout VMDKInfo,
                                     _ write: (Int64, UnsafeRawBufferPointer) throws -> Void) throws {
        if h.descOffset != 0, h.descSize != 0 {
            var desc = [UInt8](repeating: 0, count: Int(h.descSize) * Int(sector))
            do {
                try input.skip(to: Int64(h.descOffset) * sector)
                try input.readFull(&desc, 0..<desc.count)
            } catch let e as VMDKError {
                throw VMDKError("reading VMDK descriptor: \(e)")
            }
            info.createType = createType(desc[...])
        }
        if h.overhead <= maxOverhead, Int64(h.overhead) * sector > input.pos {
            do { try input.skip(to: Int64(h.overhead) * sector) } catch let e as VMDKError { throw VMDKError("reading VMDK overhead: \(e)") }
        }

        let sec = UInt64(sector)
        let maxCompressed = UInt64(info.grainBytes) + UInt64(info.grainBytes) / 2 + 2 * sec
        var buf = [UInt8](repeating: 0, count: Int((12 + maxCompressed + sec - 1) / sec * sec))
        var grain = [UInt8](repeating: 0, count: Int(info.grainBytes))
        let inflater = try Inflater()
        while true {
            let at = input.pos
            do { try input.readFull(&buf, 0..<Int(sector)) } catch let e as VMDKError {
                throw VMDKError("reading marker: \(e) (missing end-of-stream marker)")
            }
            let val = u64(buf, 0)
            let size = UInt64(u32(buf, 8))
            if size == 0 {
                let type = u32(buf, 12)
                if type == 0 { return }
                if val > h.capacity { throw VMDKError("metadata marker type \(type) at byte \(at) claims \(val) sectors") }
                do { try input.skip(to: input.pos + Int64(val) * sector) } catch let e as VMDKError {
                    throw VMDKError("metadata marker type \(type) at byte \(at): \(e)")
                }
                continue
            }
            if size > maxCompressed { throw VMDKError("grain at byte \(at) claims \(size) compressed bytes") }
            if val >= h.capacity { throw VMDKError("grain at byte \(at) maps beyond capacity (LBA \(val))") }
            let total = Int((12 + size + sec - 1) / sec * sec)
            do { try input.readFull(&buf, Int(sector)..<total) } catch let e as VMDKError { throw VMDKError("grain at byte \(at): \(e)") }
            let off = Int64(val) * sector
            let n: Int
            switch inflater.inflate(buf[12..<12 + Int(size)], into: &grain) {
            case .inflated(let count): n = count
            case .tooLong: throw VMDKError("grain at byte \(at) inflates beyond \(grain.count) bytes")
            case .failed(let why): throw VMDKError("grain at byte \(at): zlib: \(why)")
            }
            if n < grain.count, off + Int64(n) != info.capacity {
                throw VMDKError("grain at byte \(at) inflates to \(n) bytes, want \(grain.count)")
            }
            if off + Int64(n) > info.capacity { throw VMDKError("grain at byte \(at) ends beyond capacity (LBA \(val))") }
            try grain.withUnsafeBytes { try write(off, UnsafeRawBufferPointer(rebasing: $0[..<n])) }
        }
    }
}

/// One RFC 1950 stream per call; zlib checks the header and the Adler-32 trailer.
final class Inflater {
    enum Result: Equatable {
        case inflated(Int)
        case tooLong
        case failed(String)
    }

    private var stream = z_stream()

    init() throws {
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw VMDKError("zlib: inflateInit failed")
        }
    }

    deinit { inflateEnd(&stream) }

    func inflate(_ input: ArraySlice<UInt8>, into output: inout [UInt8]) -> Result {
        guard inflateReset(&stream) == Z_OK else { return .failed("inflateReset failed") }
        var probe: [UInt8] = [0]
        return input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                probe.withUnsafeMutableBytes { extra in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(src.count)
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(dst.count)
                    var rc = CZlib.inflate(&stream, Z_FINISH)
                    let n = dst.count - Int(stream.avail_out)
                    if rc == Z_BUF_ERROR, stream.avail_out == 0 {
                        stream.next_out = extra.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = 1
                        rc = CZlib.inflate(&stream, Z_FINISH)
                        if stream.avail_out == 0 { return .tooLong }
                    }
                    switch rc {
                    case Z_STREAM_END: return .inflated(n)
                    case Z_BUF_ERROR: return .failed("unexpected EOF")
                    default: return .failed(stream.msg.map { String(cString: $0) } ?? "error \(rc)")
                    }
                }
            }
        }
    }
}

/// Reads members of an .ova (tar) or VMware .zip through /usr/bin/tar, whose libarchive reads both.
public enum VMDKContainer {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    static func checkKind(_ path: URL) throws {
        guard ["ova", "zip"].contains(path.pathExtension.lowercased()) else {
            throw VMDKError("\(path.path): unsupported container (want .ova or .zip)")
        }
    }

    static func runTar(_ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = tar
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw VMDKError("tar \(arguments.joined(separator: " ")): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    /// Regular members with their sizes (-1 when the listing does not show one).
    public static func members(_ path: URL) throws -> [(name: String, size: Int64)] {
        try checkKind(path)
        let names = try runTar(["-tf", path.path]).split(separator: "\n").map(String.init)
        let long = try runTar(["-tvf", path.path]).split(separator: "\n")
        guard names.count == long.count else { throw VMDKError("\(path.path): tar listings disagree") }
        return zip(names, long).compactMap { name, line in
            guard !name.hasSuffix("/"), !line.hasPrefix("d") else { return nil }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return (name, fields.count > 4 ? Int64(fields[4]) ?? -1 : -1)
        }
    }

    /// The single *.vmdk member.
    public static func findDisk(_ path: URL) throws -> String {
        let disks = try members(path).map(\.name).filter { ($0 as NSString).pathExtension.lowercased() == "vmdk" }
        guard disks.count == 1 else { throw VMDKError("\(path.path): found \(disks.count) .vmdk members, want exactly 1") }
        return disks[0]
    }

    /// Starts `tar -xOf` for `member`; the caller reads the handle to its end and waits for the process.
    public static func open(_ path: URL, member: String) throws -> (process: Process, output: FileHandle, size: Int64) {
        let matches = try members(path).filter { $0.name == member }
        switch matches.count {
        case 0: throw VMDKError("\(path.path): no member \"\(member)\"")
        case 1: break
        default: throw VMDKError("\(path.path): member \"\(member)\" appears \(matches.count) times")
        }
        let p = Process()
        p.executableURL = tar
        p.arguments = ["-xOf", path.path, member]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        return (p, out.fileHandleForReading, matches[0].size)
    }

    /// Decodes the container's single VMDK; `progress` gets the member bytes read and the member size.
    @discardableResult
    public static func decodeDisk(_ path: URL, progress: (Int64, Int64) -> Void = { _, _ in },
                                  write: (Int64, UnsafeRawBufferPointer) throws -> Void) throws -> VMDKInfo {
        let disk = try findDisk(path)
        let (process, output, size) = try open(path, member: disk)
        let fd = output.fileDescriptor
        let read = VMDK.reader(fd: fd)
        var consumed: Int64 = 0
        var finished = false
        defer {
            if !finished, process.isRunning { process.terminate() }
            try? output.close()
            process.waitUntilExit()
        }
        do {
            let info = try VMDK.decode(read: { buffer in
                let n = try read(buffer)
                consumed += Int64(n)
                return n
            }, write: { off, data in
                try write(off, data)
                progress(consumed, size)
            })
            var rest = [UInt8](repeating: 0, count: 1 << 16)
            while try rest.withUnsafeMutableBytes({ try read($0) }) > 0 {}
            process.waitUntilExit()
            finished = true
            guard process.terminationStatus == 0 else {
                let message = (process.standardError as? Pipe).map {
                    String(decoding: $0.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                } ?? ""
                throw VMDKError("tar -xOf: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return info
        } catch let e as VMDKError {
            throw VMDKError("converting \(path.path): \(disk): \(e)")
        }
    }
}
