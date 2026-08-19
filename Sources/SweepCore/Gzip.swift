import Foundation
import CZlib

/// Live Sets are gzip streams. zlib's windowBits=47 auto-detects gzip vs zlib
/// headers, which also lets us read the occasional plain-deflate file.
public enum Gunzip {
    public static func inflate(_ input: Data) throws -> Data {
        if input.count < 2 { return input }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 47, ZLIB_VERSION,
                                   Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw SweepError.badGzip }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(input.count * 8)
        let chunkSize = 1 << 18
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)

            repeat {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { buf -> Int in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    // Truncated or corrupt files are common on synced drives.
                    // Keep whatever decoded cleanly rather than failing the scan.
                    if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                        throw SweepError.badGzip
                    }
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }
                if status == Z_STREAM_END { break }
                if produced == 0 && stream.avail_in == 0 { break }
            } while true
        }
        return output
    }
}

public enum SweepError: Error { case badGzip, unreadable }
