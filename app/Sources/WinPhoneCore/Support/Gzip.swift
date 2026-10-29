import Compression
import Foundation

/// Gzip decoding for message payloads. The phone may compress a payload and mark the envelope
/// with `_isGzippedCompressed`.
public enum Gzip {
    /// Largest output accepted, so a small hostile input cannot exhaust memory.
    public static let maxOutput = 64 << 20

    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Decompresses a gzip stream. Returns nil when the input is not valid gzip or the output
    /// would exceed `maxOutput`.
    public static func decompress(_ data: Data, maxOutput: Int = Gzip.maxOutput) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        // Optional header fields: extra, name, comment, header checksum.
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        // The last four bytes give the uncompressed size modulo 2^32.
        let tail = bytes.count - 4
        let declared = Int(bytes[tail]) | Int(bytes[tail + 1]) << 8 | Int(bytes[tail + 2]) << 16 | Int(bytes[tail + 3]) << 24
        guard declared <= maxOutput else { return nil }
        let body = Array(bytes[index..<(bytes.count - 8)])

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        var output = Data()
        let chunkSize = 64 << 10
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        return body.withUnsafeBufferPointer { source -> Data? in
            guard let base = source.baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { return nil }
                output.append(chunk, count: chunkSize - stream.pointee.dst_size)
                guard output.count <= maxOutput else { return nil }
                if status == COMPRESSION_STATUS_END { return output }
                // No progress and not finished: the stream is truncated.
                if stream.pointee.src_size == 0, stream.pointee.dst_size == chunkSize { return nil }
            }
        }
    }
}
