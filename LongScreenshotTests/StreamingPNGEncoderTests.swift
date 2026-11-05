import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LongScreenshot

@Suite(.serialized)
struct StreamingPNGEncoderTests {
    @Test func encodedPNGRoundTripsBackToTheCapturedPixels() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let width = 37
        let firstTile = makePixels(width: width, height: 11, seed: 1)
        let secondTile = makePixels(width: width, height: 5, seed: 2)
        let artifact = try makeArtifact(width: width, tiles: [firstTile, secondTile], in: scratch)

        let destination = scratch.appendingPathComponent("capture.png")
        try StreamingPNGEncoder().write(artifact: artifact, to: destination)

        let decoded = try decodeRGBA(at: destination)
        #expect(decoded.width == width)
        #expect(decoded.height == 16)
        #expect(decoded.pixels == firstTile.pixels + secondTile.pixels)
    }

    @Test func encodedPNGRoundTripsASinglePixelWideCapture() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tile = makePixels(width: 1, height: 4, seed: 7)
        let artifact = try makeArtifact(width: 1, tiles: [tile], in: scratch)

        let destination = scratch.appendingPathComponent("narrow.png")
        try StreamingPNGEncoder().write(artifact: artifact, to: destination)

        let decoded = try decodeRGBA(at: destination)
        #expect(decoded.width == 1)
        #expect(decoded.height == 4)
        #expect(decoded.pixels == tile.pixels)
    }

    @Test func encodedPNGIsCompressedRatherThanStoredVerbatim() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Repeated rows are what a scrolling capture of a document looks like.
        let width = 256
        let height = 256
        let tile = RawTile(
            width: width,
            height: height,
            pixels: (0..<(width * height)).flatMap { index -> [UInt8] in
                let column = UInt8(truncatingIfNeeded: index % width)
                return [column, 128, 32, 255]
            }
        )
        let artifact = try makeArtifact(width: width, tiles: [tile], in: scratch)

        let destination = scratch.appendingPathComponent("compressible.png")
        try StreamingPNGEncoder().write(artifact: artifact, to: destination)

        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int
        )
        // The raw RGBA scanlines are 262_144 bytes before PNG overhead.
        #expect(size < width * height * 4 / 10)

        let decoded = try decodeRGBA(at: destination)
        #expect(decoded.pixels == tile.pixels)
    }

    @Test func encodingRejectsTilesThatDoNotFillTheDeclaredHeight() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tile = makePixels(width: 4, height: 2, seed: 3)
        let artifact = try makeArtifact(width: 4, tiles: [tile], in: scratch, heightOverride: 99)

        #expect(throws: ScrollingCaptureError.self) {
            try StreamingPNGEncoder().write(
                artifact: artifact,
                to: scratch.appendingPathComponent("broken.png")
            )
        }
    }

    // MARK: - Helpers

    private struct RawTile {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private struct DecodedImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StreamingPNGEncoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePixels(width: Int, height: Int, seed: UInt8) -> RawTile {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                pixels[offset] = UInt8(truncatingIfNeeded: row &* 7 &+ column &* 3 &+ Int(seed))
                pixels[offset + 1] = UInt8(truncatingIfNeeded: column &* 11 &+ Int(seed))
                pixels[offset + 2] = UInt8(truncatingIfNeeded: row &* 5 &+ Int(seed) &* 2)
                pixels[offset + 3] = 255
            }
        }
        return RawTile(width: width, height: height, pixels: pixels)
    }

    private func makeArtifact(
        width: Int,
        tiles: [RawTile],
        in directory: URL,
        heightOverride: Int? = nil
    ) throws -> ScrollingCaptureArtifact {
        var rawTiles: [ScrollingCaptureRawTile] = []
        for (index, tile) in tiles.enumerated() {
            let url = directory.appendingPathComponent(String(format: "%05d.rgba", index))
            try Data(tile.pixels).write(to: url)
            rawTiles.append(ScrollingCaptureRawTile(url: url, height: tile.height))
        }
        return ScrollingCaptureArtifact(
            width: width,
            height: heightOverride ?? tiles.reduce(0) { $0 + $1.height },
            tiles: rawTiles,
            temporaryDirectory: directory
        )
    }

    /// Decodes the file back to straight RGBA so every channel, alpha included,
    /// can be compared against the tiles that went in.
    private func decodeRGBA(at url: URL) throws -> DecodedImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedImage(width: width, height: height, pixels: bytes)
    }
}
