import Compression
import Foundation

/// Minimal streaming PNG writer for 8-bit RGBA scanlines. Compressed bytes are
/// appended directly as bounded IDAT chunks, so neither the full raster nor a
/// second full compressed buffer is retained.
final class PNGStreamWriter {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let outputBufferSize = 64 * 1_024
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1
                ? 0xEDB8_8320 ^ (crc >> 1)
                : crc >> 1
        }
        return crc
    }

    private var stream: compression_stream
    private let emptySource: UnsafeMutablePointer<UInt8>
    private let emptyDestination: UnsafeMutablePointer<UInt8>
    private var pngData = Data()
    private var outputBuffer = [UInt8](
        repeating: 0,
        count: PNGStreamWriter.outputBufferSize
    )
    private let maximumBytes: Int
    private var streamIsInitialized = false
    private var isFinished = false
    private var adlerA: UInt32 = 1
    private var adlerB: UInt32 = 0

    init(width: Int, height: Int, maximumBytes: Int) throws {
        let emptySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let emptyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        self.emptySource = emptySource
        self.emptyDestination = emptyDestination
        stream = compression_stream(
            dst_ptr: emptyDestination,
            dst_size: 0,
            src_ptr: UnsafePointer(emptySource),
            src_size: 0,
            state: nil
        )
        self.maximumBytes = maximumBytes
        pngData.reserveCapacity(min(maximumBytes, max(64 * 1_024, height * 64)))
        pngData.append(contentsOf: Self.signature)

        var header = Data()
        Self.appendBigEndian(UInt32(width), to: &header)
        Self.appendBigEndian(UInt32(height), to: &header)
        header.append(contentsOf: [8, 6, 0, 0, 0])
        try appendChunk(type: "IHDR", bytes: header)

        let status = compression_stream_init(
            &stream,
            COMPRESSION_STREAM_ENCODE,
            COMPRESSION_ZLIB
        )
        guard status != COMPRESSION_STATUS_ERROR else {
            emptySource.deallocate()
            emptyDestination.deallocate()
            throw WebMarkdownRendererError.pngEncodingFailed
        }
        streamIsInitialized = true

        // Apple's Compression framework emits raw DEFLATE for
        // COMPRESSION_ZLIB. PNG requires a zlib stream around that payload.
        try appendChunk(type: "IDAT", bytes: Data([0x78, 0x9C]))
    }

    deinit {
        if streamIsInitialized {
            compression_stream_destroy(&stream)
        }
        emptySource.deallocate()
        emptyDestination.deallocate()
    }

    func writeScanline(_ bytes: [UInt8]) throws {
        guard !isFinished else {
            throw WebMarkdownRendererError.pngEncodingFailed
        }
        updateAdler32(with: bytes)
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            try process(
                source: baseAddress,
                sourceSize: rawBuffer.count,
                finalize: false
            )
        }
    }

    func finish() throws -> Data {
        guard !isFinished else { return pngData }
        try process(source: nil, sourceSize: 0, finalize: true)
        var trailer = Data()
        Self.appendBigEndian((adlerB << 16) | adlerA, to: &trailer)
        try appendChunk(type: "IDAT", bytes: trailer)
        try appendChunk(type: "IEND", bytes: Data())
        isFinished = true
        return pngData
    }

    private func updateAdler32(with bytes: [UInt8]) {
        let modulus: UInt32 = 65_521
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 5_552, bytes.count)
            for byte in bytes[offset..<end] {
                adlerA += UInt32(byte)
                adlerB += adlerA
            }
            adlerA %= modulus
            adlerB %= modulus
            offset = end
        }
    }

    private func process(
        source: UnsafePointer<UInt8>?,
        sourceSize: Int,
        finalize: Bool
    ) throws {
        stream.src_ptr = source ?? UnsafePointer(emptySource)
        stream.src_size = sourceSize
        let flags = finalize
            ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            : 0

        while true {
            var status = COMPRESSION_STATUS_OK
            var produced = 0
            outputBuffer.withUnsafeMutableBytes { rawBuffer in
                stream.dst_ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress
                    ?? emptyDestination
                stream.dst_size = rawBuffer.count
                status = compression_stream_process(&stream, flags)
                produced = rawBuffer.count - stream.dst_size
            }

            guard status != COMPRESSION_STATUS_ERROR else {
                throw WebMarkdownRendererError.pngEncodingFailed
            }
            if produced > 0 {
                try outputBuffer.withUnsafeBytes { rawBuffer in
                    let bytes = UnsafeRawBufferPointer(
                        start: rawBuffer.baseAddress,
                        count: produced
                    )
                    try appendChunk(type: "IDAT", bytes: bytes)
                }
            }

            if status == COMPRESSION_STATUS_END {
                return
            }
            if !finalize && stream.src_size == 0 {
                return
            }
        }
    }

    private func appendChunk(type: String, bytes: Data) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            try appendChunk(type: type, bytes: rawBuffer)
        }
    }

    private func appendChunk(
        type: String,
        bytes: UnsafeRawBufferPointer
    ) throws {
        let typeBytes = Array(type.utf8)
        guard typeBytes.count == 4,
              bytes.count <= Int(UInt32.max) else {
            throw WebMarkdownRendererError.pngEncodingFailed
        }

        let addedByteCount = 12 + bytes.count
        guard pngData.count <= maximumBytes - addedByteCount else {
            throw WebMarkdownRendererError.encodedImageTooLarge(
                maximumBytes: maximumBytes
            )
        }

        Self.appendBigEndian(UInt32(bytes.count), to: &pngData)
        pngData.append(contentsOf: typeBytes)
        if !bytes.isEmpty {
            pngData.append(bytes.bindMemory(to: UInt8.self))
        }

        var crc: UInt32 = 0xFFFF_FFFF
        Self.updateCRC(&crc, with: typeBytes)
        Self.updateCRC(&crc, with: bytes)
        Self.appendBigEndian(crc ^ 0xFFFF_FFFF, to: &pngData)
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func updateCRC(_ crc: inout UInt32, with bytes: [UInt8]) {
        bytes.withUnsafeBytes { updateCRC(&crc, with: $0) }
    }

    private static func updateCRC(
        _ crc: inout UInt32,
        with bytes: UnsafeRawBufferPointer
    ) {
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = Self.crcTable[index] ^ (crc >> 8)
        }
    }
}
