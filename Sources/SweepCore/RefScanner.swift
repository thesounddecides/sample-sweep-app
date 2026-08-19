import Foundation

/// Everything a single Live Set (or device preset) refers to.
public struct RefIndex: Sendable {
    public var absolutePaths: Set<String> = []
    public var basenames: Set<String> = []

    public mutating func formUnion(_ other: RefIndex) {
        absolutePaths.formUnion(other.absolutePaths)
        basenames.formUnion(other.basenames)
    }
}

public enum Media {
    /// Extensions Live can reference as a clip source.
    public static let audio: Set<String> = [
        "wav", "aif", "aiff", "mp3", "flac", "m4a", "aac", "ogg",
        "wv", "caf", "sd2", "au", "snd", "rex", "rx2",
        "mov", "mp4", "avi", "m4v",
    ]
    /// File types that can hold sample references.
    public static let referenceHolding: Set<String> = [
        "als", "alc", "adg", "adv", "agr", "ams", "amxd",
    ]

    public static func isAudio(_ name: String) -> Bool {
        audio.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Scans decompressed Live XML for sample references.
///
/// Deliberately byte-level: a Live Set decompresses to tens of megabytes, and
/// building a Swift String per attribute would dominate the runtime. We only
/// materialise a String once the raw bytes already end in an audio extension.
public enum RefScanner {

    private static let valueMarker = Array("Value=\"".utf8)
    private static let pathMarker = Array("<Path ".utf8)

    public static func scan(_ bytes: [UInt8], deep: Bool = false) -> RefIndex {
        var index = RefIndex()
        let n = bytes.count
        let m = valueMarker.count
        guard n > m else { return index }

        var i = 0
        while i <= n - m {
            // Cheap first-byte reject before the full compare.
            if bytes[i] != 0x56 /* V */ { i += 1; continue }
            var matched = true
            for k in 1..<m where bytes[i + k] != valueMarker[k] { matched = false; break }
            if !matched { i += 1; continue }

            let start = i + m
            var end = start
            while end < n && bytes[end] != 0x22 /* " */ { end += 1 }
            if end >= n { break }

            if end > start, let ext = extensionBytes(bytes, start, end),
               Media.audio.contains(ext) {
                let isPath = i >= pathMarker.count
                    && matches(bytes, at: i - pathMarker.count, pathMarker)
                addValue(bytes, start, end, isAbsolutePath: isPath, into: &index)
            }
            i = end + 1
        }

        if deep { index.basenames.formUnion(PluginBlobScanner.names(in: bytes)) }
        return index
    }

    private static func matches(_ b: [UInt8], at pos: Int, _ pattern: [UInt8]) -> Bool {
        guard pos >= 0, pos + pattern.count <= b.count else { return false }
        for k in 0..<pattern.count where b[pos + k] != pattern[k] { return false }
        return true
    }

    /// Lowercased extension of the byte range, without allocating the value.
    private static func extensionBytes(_ b: [UInt8], _ start: Int, _ end: Int) -> String? {
        var dot = -1
        var j = end - 1
        let floor = max(start, end - 6)
        while j >= floor {
            if b[j] == 0x2E /* . */ { dot = j; break }
            j -= 1
        }
        guard dot >= 0, dot + 1 < end else { return nil }
        var ext = ""
        ext.reserveCapacity(end - dot)
        for k in (dot + 1)..<end {
            let c = b[k]
            guard c < 0x80 else { return nil }
            ext.append(Character(UnicodeScalar(c >= 65 && c <= 90 ? c + 32 : c)))
        }
        return ext
    }

    private static func addValue(_ b: [UInt8], _ start: Int, _ end: Int,
                                 isAbsolutePath: Bool, into index: inout RefIndex) {
        guard let raw = String(bytes: b[start..<end], encoding: .utf8) else { return }
        let unescaped = xmlUnescape(raw)

        if isAbsolutePath {
            let norm = unescaped.precomposedStringWithCanonicalMapping
            index.absolutePaths.insert(norm)
            index.basenames.insert(leaf(norm))
            return
        }

        index.basenames.insert(leaf(unescaped))
        // Browser and pack references are percent-encoded HFS-style paths,
        // e.g. "#One%20Shot%20FX:FX%20Oop.aif".
        if unescaped.contains("%"),
           let decoded = unescaped.removingPercentEncoding, decoded != unescaped {
            index.basenames.insert(leaf(decoded))
        }
    }

    /// Last path segment, across every separator Live has used: POSIX "/",
    /// Windows "\", and the old HFS ":" browser paths.
    public static func leaf(_ value: String) -> String {
        var out = value
        for sep in ["/", "\\", ":"] {
            if let r = out.range(of: sep, options: .backwards) {
                out = String(out[r.upperBound...])
            }
        }
        return out.precomposedStringWithCanonicalMapping
    }

    public static func xmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&apos;", "'"),
                       ("&#13;", "\r"), ("&#10;", "\n")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out
    }
}

/// Third-party plugins store their state as hex <Buffer> blobs, opaque to the
/// FileRef parse. A sampler VST pointing at a file in the project folder would
/// be invisible otherwise, so optionally decode and look for sample names.
enum PluginBlobScanner {
    private static let open = Array("<Buffer>".utf8)
    private static let close = Array("</Buffer>".utf8)

    static func names(in bytes: [UInt8]) -> Set<String> {
        var found: Set<String> = []
        var i = 0
        let n = bytes.count
        while i < n {
            guard let s = find(bytes, open, from: i) else { break }
            guard let e = find(bytes, close, from: s + open.count) else { break }
            let hex = bytes[(s + open.count)..<e]
            if let raw = decodeHex(hex) {
                harvest(raw, into: &found)
                // Windows-built plugins store paths as UTF-16LE.
                var ascii: [UInt8] = []
                ascii.reserveCapacity(raw.count / 2)
                var k = 0
                while k + 1 < raw.count {
                    if raw[k + 1] == 0 { ascii.append(raw[k]) }
                    k += 2
                }
                harvest(ascii, into: &found)
            }
            i = e + close.count
        }
        return found
    }

    private static func harvest(_ raw: [UInt8], into found: inout Set<String>) {
        var run: [UInt8] = []
        for byte in raw {
            if byte >= 0x20 && byte < 0x7F {
                run.append(byte)
                if run.count > 400 { run.removeFirst(run.count - 400) }
            } else {
                flush(&run, into: &found)
            }
        }
        flush(&run, into: &found)
    }

    private static func flush(_ run: inout [UInt8], into found: inout Set<String>) {
        defer { run.removeAll(keepingCapacity: true) }
        guard run.count > 4, let s = String(bytes: run, encoding: .utf8) else { return }
        for token in s.split(whereSeparator: { $0 == "\0" || $0 == "\t" }) {
            let t = String(token)
            if Media.isAudio(t) { found.insert(RefScanner.leaf(t)) }
        }
    }

    private static func find(_ b: [UInt8], _ pat: [UInt8], from: Int) -> Int? {
        guard pat.count > 0, b.count >= pat.count else { return nil }
        var i = max(0, from)
        while i <= b.count - pat.count {
            if b[i] == pat[0] {
                var ok = true
                for k in 1..<pat.count where b[i + k] != pat[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    private static func decodeHex(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(slice.count / 2)
        var hi: UInt8? = nil
        for c in slice {
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            case 0x20, 0x0A, 0x0D, 0x09: continue
            default: return nil
            }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        return out
    }
}
