import Compression
import Foundation

/// Streams the disk-backed capture tiles into a PNG without ever materializing
/// the full image in memory. Rows are converted to opaque RGB, filtered, and
/// piped through a zlib deflate stream so a tall capture stays a reasonably
/// sized file.
struct StreamingPNGEncoder {
    private static let idatChunkSize = 64 * 1024
    private static let bytesPerPixel = 4

    func write(artifact: ScrollingCaptureArtifact, to destination: URL) throws {
        guard artifact.width > 0, artifact.height > 0 else {
            throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot is empty."))
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data([137, 80, 78, 71, 13, 10, 26, 10]))
        // Colour type 6 (RGBA), matching the tile layout byte for byte. Dropping
        // the alpha channel would only shrink the file by well under a percent
        // once deflate has seen it, which is not worth assuming every captured
        // pixel is opaque.
        try writeChunk(
            type: "IHDR",
            data: be32(artifact.width) + be32(artifact.height) + Data([8, 6, 0, 0, 0]),
            to: handle
        )
        // Untagged PNGs are already read as sRGB, so saying so explicitly changes
        // nothing about how the file renders and helps decoders that ask.
        try writeChunk(type: "sRGB", data: Data([0]), to: handle)
        try writeChunk(type: "gAMA", data: be32(45_455), to: handle)
        try writeChunk(type: "cHRM", data: Self.sRGBChromaticities, to: handle)

        var idatBuffer = Data([0x78, 0x01])
        idatBuffer.reserveCapacity(Self.idatChunkSize * 2)
        let flushFullChunks = {
            while idatBuffer.count >= Self.idatChunkSize {
                try writeChunk(type: "IDAT", data: idatBuffer.prefix(Self.idatChunkSize), to: handle)
                idatBuffer.removeFirst(Self.idatChunkSize)
            }
        }

        let deflater = try DeflateEncoder { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty {
                idatBuffer.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            }
            try flushFullChunks()
        }

        var adler = Adler32()
        try encodeRows(of: artifact, adler: &adler, into: deflater)
        try deflater.finish()

        idatBuffer.append(be32(adler.value))
        try flushFullChunks()
        if !idatBuffer.isEmpty {
            try writeChunk(type: "IDAT", data: idatBuffer, to: handle)
        }
        try writeChunk(type: "IEND", data: Data(), to: handle)
    }

    private func encodeRows(
        of artifact: ScrollingCaptureArtifact,
        adler: inout Adler32,
        into deflater: DeflateEncoder
    ) throws {
        let width = artifact.width
        let rowLength = width * Self.bytesPerPixel
        var previousRow = [UInt8](repeating: 0, count: rowLength)
        var currentRow = [UInt8](repeating: 0, count: rowLength)
        var filteredRow = [UInt8](repeating: 0, count: rowLength + 1)
        var scratchRow = [UInt8](repeating: 0, count: rowLength)
        var rowsEncoded = 0

        for tile in artifact.tiles {
            let tileData = try Data(contentsOf: tile.url, options: .mappedIfSafe)
            guard tileData.count >= rowLength * tile.height else {
                throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot data is incomplete."))
            }

            try tileData.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot data is incomplete."))
                }
                let source = base.assumingMemoryBound(to: UInt8.self)

                for row in 0..<tile.height {
                    let rowStart = source.advanced(by: row * rowLength)
                    currentRow.withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress?.update(from: rowStart, count: rowLength)
                    }

                    ScanlineFilter.encode(
                        current: currentRow,
                        previous: previousRow,
                        into: &filteredRow,
                        scratch: &scratchRow
                    )
                    adler.update(filteredRow)
                    try filteredRow.withUnsafeBufferPointer { try deflater.append($0) }
                    swap(&previousRow, &currentRow)
                    rowsEncoded += 1
                }
            }
        }

        guard rowsEncoded == artifact.height else {
            throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot data is incomplete."))
        }
    }

    private func writeChunk(type: String, data: Data, to handle: FileHandle) throws {
        let typeData = Data(type.utf8)
        var crc = CRC32.begin()
        crc = CRC32.update(crc, with: typeData)
        crc = CRC32.update(crc, with: data)

        try handle.write(contentsOf: be32(data.count))
        try handle.write(contentsOf: typeData)
        if !data.isEmpty {
            try handle.write(contentsOf: data)
        }
        try handle.write(contentsOf: be32(CRC32.finalize(crc)))
    }

    /// The chromaticities the PNG specification lists for sRGB, recommended
    /// alongside the sRGB chunk for decoders that do not understand it.
    private static let sRGBChromaticities: Data = {
        let points: [UInt32] = [31_270, 32_900, 64_000, 33_000, 30_000, 60_000, 15_000, 6_000]
        return points.reduce(into: Data()) { data, point in
            data.append(contentsOf: [
                UInt8(truncatingIfNeeded: point >> 24),
                UInt8(truncatingIfNeeded: point >> 16),
                UInt8(truncatingIfNeeded: point >> 8),
                UInt8(truncatingIfNeeded: point)
            ])
        }
    }()

    private func be32(_ value: Int) -> Data { be32(UInt32(value)) }
    private func be32(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }
}

/// Wraps `compression_stream` so filtered scanlines can be pushed in and raw
/// DEFLATE output comes back out in bounded chunks.
private final class DeflateEncoder {
    private static let outputCapacity = 64 * 1024

    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: DeflateEncoder.outputCapacity)
    private let emit: (UnsafeRawBufferPointer) throws -> Void
    private var isInitialized = false

    init(emit: @escaping (UnsafeRawBufferPointer) throws -> Void) throws {
        self.emit = emit
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            output.deallocate()
            throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot could not be compressed."))
        }
        isInitialized = true
        resetDestination()
    }

    deinit {
        if isInitialized {
            compression_stream_destroy(stream)
        }
        stream.deallocate()
        output.deallocate()
    }

    func append(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        stream.pointee.src_ptr = base
        stream.pointee.src_size = bytes.count
        defer {
            stream.pointee.src_ptr = UnsafePointer(output)
            stream.pointee.src_size = 0
        }

        while stream.pointee.src_size > 0 {
            guard compression_stream_process(stream, 0) != COMPRESSION_STATUS_ERROR else {
                throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot could not be compressed."))
            }
            if stream.pointee.dst_size == 0 {
                try flush()
            }
        }
    }

    func finish() throws {
        stream.pointee.src_ptr = UnsafePointer(output)
        stream.pointee.src_size = 0

        var status = COMPRESSION_STATUS_OK
        repeat {
            status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            guard status != COMPRESSION_STATUS_ERROR else {
                throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot could not be compressed."))
            }
            try flush()
        } while status != COMPRESSION_STATUS_END
    }

    private func flush() throws {
        let produced = Self.outputCapacity - stream.pointee.dst_size
        guard produced > 0 else { return }
        try emit(UnsafeRawBufferPointer(start: output, count: produced))
        resetDestination()
    }

    private func resetDestination() {
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = Self.outputCapacity
    }
}

/// Picks the PNG filter that makes each scanline cheapest to compress, using the
/// minimum-sum-of-absolute-differences heuristic from the PNG specification.
private enum ScanlineFilter {
    private static let bytesPerPixel = 4
    private static let candidates: [UInt8] = [0, 1, 2, 3, 4]

    static func encode(
        current: [UInt8],
        previous: [UInt8],
        into output: inout [UInt8],
        scratch: inout [UInt8]
    ) {
        guard !current.isEmpty else {
            output[0] = 0
            return
        }

        current.withUnsafeBufferPointer { source in
            previous.withUnsafeBufferPointer { prior in
                scratch.withUnsafeMutableBufferPointer { work in
                    output.withUnsafeMutableBufferPointer { result in
                        var bestScore = Int.max
                        for candidate in candidates {
                            let score = apply(candidate, current: source, previous: prior, into: work)
                            guard score < bestScore else { continue }
                            bestScore = score
                            result[0] = candidate
                            for index in 0..<work.count {
                                result[index + 1] = work[index]
                            }
                        }
                    }
                }
            }
        }
    }

    private static func apply(
        _ filter: UInt8,
        current: UnsafeBufferPointer<UInt8>,
        previous: UnsafeBufferPointer<UInt8>,
        into work: UnsafeMutableBufferPointer<UInt8>
    ) -> Int {
        let count = current.count
        let bpp = bytesPerPixel
        var score = 0

        switch filter {
        case 0:
            for index in 0..<count {
                let value = current[index]
                work[index] = value
                score += magnitude(value)
            }
        case 1:
            for index in 0..<min(bpp, count) {
                let value = current[index]
                work[index] = value
                score += magnitude(value)
            }
            for index in bpp..<count {
                let value = current[index] &- current[index - bpp]
                work[index] = value
                score += magnitude(value)
            }
        case 2:
            for index in 0..<count {
                let value = current[index] &- previous[index]
                work[index] = value
                score += magnitude(value)
            }
        case 3:
            for index in 0..<min(bpp, count) {
                let value = current[index] &- UInt8(truncatingIfNeeded: Int(previous[index]) / 2)
                work[index] = value
                score += magnitude(value)
            }
            for index in bpp..<count {
                let average = (Int(current[index - bpp]) + Int(previous[index])) / 2
                let value = current[index] &- UInt8(truncatingIfNeeded: average)
                work[index] = value
                score += magnitude(value)
            }
        default:
            // For the leading pixel the left and upper-left neighbours are zero,
            // which makes the Paeth predictor collapse to the pixel above.
            for index in 0..<min(bpp, count) {
                let value = current[index] &- previous[index]
                work[index] = value
                score += magnitude(value)
            }
            for index in bpp..<count {
                let predictor = paeth(current[index - bpp], previous[index], previous[index - bpp])
                let value = current[index] &- predictor
                work[index] = value
                score += magnitude(value)
            }
        }

        return score
    }

    private static func paeth(_ left: UInt8, _ above: UInt8, _ upperLeft: UInt8) -> UInt8 {
        let estimate = Int(left) + Int(above) - Int(upperLeft)
        let distanceLeft = abs(estimate - Int(left))
        let distanceAbove = abs(estimate - Int(above))
        let distanceUpperLeft = abs(estimate - Int(upperLeft))
        if distanceLeft <= distanceAbove && distanceLeft <= distanceUpperLeft {
            return left
        }
        return distanceAbove <= distanceUpperLeft ? above : upperLeft
    }

    private static func magnitude(_ value: UInt8) -> Int {
        let signed = Int(Int8(bitPattern: value))
        return signed < 0 ? -signed : signed
    }
}

private struct Adler32 {
    private static let modulus: UInt32 = 65_521
    /// Largest run that cannot overflow the 32-bit accumulators.
    private static let maximumRun = 5_552

    private var a: UInt32 = 1
    private var b: UInt32 = 0

    mutating func update(_ data: [UInt8]) {
        var lower = a
        var upper = b
        data.withUnsafeBufferPointer { bytes in
            var index = 0
            while index < bytes.count {
                let end = min(index + Self.maximumRun, bytes.count)
                while index < end {
                    lower &+= UInt32(bytes[index])
                    upper &+= lower
                    index += 1
                }
                lower %= Self.modulus
                upper %= Self.modulus
            }
        }
        a = lower
        b = upper
    }

    var value: UInt32 { (b << 16) | a }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
        return crc
    }

    static func begin() -> UInt32 { 0xffff_ffff }

    static func finalize(_ crc: UInt32) -> UInt32 { ~crc }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var result = crc
        data.withUnsafeBytes { raw in
            for byte in raw {
                result = (result >> 8) ^ table[Int((result ^ UInt32(byte)) & 0xff)]
            }
        }
        return result
    }
}
