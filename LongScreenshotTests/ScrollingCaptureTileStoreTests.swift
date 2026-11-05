import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LongScreenshot

@Suite(.serialized)
struct ScrollingCaptureTileStoreTests {
    @Test func tileStorePersistsInitialFrameAndBottomRowsInDocumentOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ScrollingCaptureTileStore(maximumHeight: 100, temporaryDirectoryProvider: { directory })

        try store.appendInitial(makeImage(rows: [.red, .green, .blue, .yellow]))
        try store.appendBottomRows(from: makeImage(rows: [.blue, .yellow, .cyan, .magenta]), count: 2)

        let artifact = try #require(store.makeArtifact())
        #expect(artifact.width == 8)
        #expect(artifact.height == 6)
        #expect(try rows(from: artifact) == [.red, .green, .blue, .yellow, .cyan, .magenta])
    }

    @Test func tileStoreRejectsAnAppendThatExceedsItsMaximumHeight() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ScrollingCaptureTileStore(maximumHeight: 5, temporaryDirectoryProvider: { directory })
        try store.appendInitial(makeImage(rows: [.red, .green, .blue, .yellow]))

        #expect(throws: ScrollingCaptureError.maximumHeightReached) {
            try store.appendBottomRows(from: makeImage(rows: [.blue, .yellow, .cyan, .magenta]), count: 2)
        }
    }

    @Test func discardingTileStoreRemovesItsTemporaryDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let store = try ScrollingCaptureTileStore(maximumHeight: 100, temporaryDirectoryProvider: { directory })
        try store.appendInitial(makeImage(rows: [.red, .green]))
        store.discard()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func previewIsBoundedWithoutMaterializingTheFullArtifact() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ScrollingCaptureTileStore(maximumHeight: 100, temporaryDirectoryProvider: { directory })
        try store.appendInitial(makeImage(rows: [.red, .green, .blue, .yellow]))
        try store.appendBottomRows(from: makeImage(rows: [.blue, .yellow, .cyan, .magenta]), count: 2)

        let preview = try #require(store.previewImage(maximumSize: CGSize(width: 4, height: 3)))
        #expect(preview.width <= 4)
        #expect(preview.height <= 3)
    }

    /// CoreGraphics counts y from the bottom, so an easy slip puts the newest
    /// rows on top of the thumbnail instead of under the history.
    @Test func previewKeepsTheHistoryAboveTheNewestRows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ScrollingCaptureTileStore(maximumHeight: 100, temporaryDirectoryProvider: { directory })
        try store.appendInitial(makeImage(rows: Array(repeating: .red, count: 8)))
        try store.appendBottomRows(from: makeImage(rows: Array(repeating: .blue, count: 8)), count: 8)

        let preview = try #require(store.previewImage(maximumSize: CGSize(width: 180, height: 320)))
        let pixels = rasterize(preview)
        let rowBytes = preview.width * 4
        #expect(TestColor(rgba: (pixels[0], pixels[1], pixels[2], pixels[3])) == .red)
        let last = (preview.height - 1) * rowBytes
        #expect(TestColor(rgba: (pixels[last], pixels[last + 1], pixels[last + 2], pixels[last + 3])) == .blue)
    }

    @Test func previewDoesNotReadHistoricalTilesFromDisk() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repository.appendingPathComponent("LongScreenshot/ScrollingCapture/ScrollingCaptureTileStore.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let previewSource = try #require(source.components(separatedBy: "func previewImage").dropFirst().first)
        #expect(!previewSource.contains("FileHandle(forReadingFrom:"))
        #expect(!previewSource.contains("tile(containingRow:"))
    }

    /// Appending only the newly revealed rows must land the exact bytes that
    /// rasterizing the whole frame and slicing its bottom rows would have, or a
    /// scrolling capture would silently lose fidelity. Uses real image data,
    /// where gradients and antialiased edges would expose any resampling.
    @Test func croppedAppendsMatchFullFrameRasterization() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try appIcon()
        let viewportHeight = 400
        let offsets = [120, 130, 150, 200]
        let store = try ScrollingCaptureTileStore(
            maximumHeight: 30_000,
            temporaryDirectoryProvider: { directory }
        )

        var expected = rasterize(viewport(of: page, top: 0, height: viewportHeight))
        try store.appendInitial(viewport(of: page, top: 0, height: viewportHeight))

        var top = 0
        for offset in offsets {
            top += offset
            let frame = viewport(of: page, top: top, height: viewportHeight)
            try store.appendBottomRows(from: frame, count: offset)
            let wholeFrame = rasterize(frame)
            expected.append(contentsOf: wholeFrame[((viewportHeight - offset) * page.width * 4)...])
        }

        let artifact = try #require(store.makeArtifact())
        #expect(artifact.width == page.width)
        #expect(artifact.height == viewportHeight + offsets.reduce(0, +))

        var stored: [UInt8] = []
        for tile in artifact.tiles {
            stored.append(contentsOf: try Data(contentsOf: tile.url))
        }
        #expect(stored == expected)
    }

    private func appIcon() throws -> CGImage {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent(
            "LongScreenshot/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"
        )
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func viewport(of image: CGImage, top: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height))!
    }

    private func rasterize(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScrollingCaptureTileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImage(rows: [TestColor]) -> CGImage {
        let width = 8
        var bytes = [UInt8](repeating: 0, count: width * rows.count * 4)
        for (row, color) in rows.enumerated() {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                bytes[offset] = color.rgba.0
                bytes[offset + 1] = color.rgba.1
                bytes[offset + 2] = color.rgba.2
                bytes[offset + 3] = color.rgba.3
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rows(from artifact: ScrollingCaptureArtifact) throws -> [TestColor] {
        var result: [TestColor] = []
        for tile in artifact.tiles {
            let bytes = Array(try Data(contentsOf: tile.url))
            for row in 0..<tile.height {
                let offset = row * artifact.width * 4
                result.append(try #require(TestColor(rgba: (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))))
            }
        }
        return result
    }
}

private enum TestColor: Equatable {
    case red, green, blue, yellow, cyan, magenta

    var rgba: (UInt8, UInt8, UInt8, UInt8) {
        switch self {
        case .red: (255, 0, 0, 255)
        case .green: (0, 255, 0, 255)
        case .blue: (0, 0, 255, 255)
        case .yellow: (255, 255, 0, 255)
        case .cyan: (0, 255, 255, 255)
        case .magenta: (255, 0, 255, 255)
        }
    }

    init?(rgba: (UInt8, UInt8, UInt8, UInt8)) {
        switch rgba {
        case (255, 0, 0, 255): self = .red
        case (0, 255, 0, 255): self = .green
        case (0, 0, 255, 255): self = .blue
        case (255, 255, 0, 255): self = .yellow
        case (0, 255, 255, 255): self = .cyan
        case (255, 0, 255, 255): self = .magenta
        default: return nil
        }
    }
}
