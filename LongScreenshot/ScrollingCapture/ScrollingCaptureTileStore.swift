import CoreGraphics
import Foundation

struct ScrollingCaptureRawTile: Sendable {
    let url: URL
    let height: Int
}

final class ScrollingCaptureArtifact: @unchecked Sendable {
    let width: Int
    let height: Int
    let tiles: [ScrollingCaptureRawTile]
    let temporaryDirectory: URL

    init(width: Int, height: Int, tiles: [ScrollingCaptureRawTile], temporaryDirectory: URL) {
        self.width = width
        self.height = height
        self.tiles = tiles
        self.temporaryDirectory = temporaryDirectory
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

final class ScrollingCaptureTileStore {
    private let maximumHeight: Int
    private let directory: URL
    private var tiles: [ScrollingCaptureRawTile] = []
    private var preview = CompactScrollingCapturePreview()
    private(set) var width = 0
    private(set) var height = 0

    init(
        maximumHeight: Int,
        temporaryDirectoryProvider: () throws -> URL = {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LongScreenshot-ScrollingCapture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    ) throws {
        self.maximumHeight = maximumHeight
        directory = try temporaryDirectoryProvider()
    }

    func appendInitial(_ image: CGImage) throws {
        guard tiles.isEmpty else { return }
        let frame = try RGBAFrame(image: image)
        guard frame.height <= maximumHeight else { throw ScrollingCaptureError.maximumHeightReached }
        width = frame.width
        try append(frame)
    }

    func appendBottomRows(from image: CGImage, count: Int) throws {
        guard image.width == width else { throw ScrollingCaptureError.incompatibleFrame }
        guard count > 0, count <= image.height, height + count <= maximumHeight else {
            throw ScrollingCaptureError.maximumHeightReached
        }
        // Crop before rasterizing so a small scroll step only costs the rows it
        // actually contributes, not a full-frame bitmap.
        guard let newRows = image.cropping(
            to: CGRect(x: 0, y: image.height - count, width: image.width, height: count)
        ) else {
            throw ScrollingCaptureError.incompatibleFrame
        }
        try append(RGBAFrame(image: newRows))
    }

    func makeArtifact() -> ScrollingCaptureArtifact? {
        guard !tiles.isEmpty else { return nil }
        return ScrollingCaptureArtifact(width: width, height: height, tiles: tiles, temporaryDirectory: directory)
    }

    func previewImage(maximumSize: CGSize) -> CGImage? {
        preview.image(maximumSize: maximumSize)
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }

    private func append(_ frame: RGBAFrame) throws {
        let url = directory.appendingPathComponent(String(format: "%05d.rgba", tiles.count))
        try Data(frame.pixels).write(to: url, options: .atomic)
        preview.append(frame.image, newHeight: height + frame.height)
        tiles.append(ScrollingCaptureRawTile(url: url, height: frame.height))
        height += frame.height
    }
}

/// A thumbnail of everything captured so far, rebuilt from itself plus the
/// newest rows so it never has to read old tiles back. Scaling is left to
/// CoreGraphics rather than a per-pixel loop, which in a Debug build cost more
/// than the rest of the frame put together.
private struct CompactScrollingCapturePreview {
    private var image: CGImage?

    mutating func append(_ rows: CGImage, newHeight: Int) {
        let scale = min(1, 180 / CGFloat(rows.width), 320 / CGFloat(newHeight))
        let newWidth = max(1, Int((CGFloat(rows.width) * scale).rounded(.down)))
        let newPreviewHeight = max(1, Int((CGFloat(newHeight) * scale).rounded(.down)))
        guard let context = Self.context(width: newWidth, height: newPreviewHeight) else {
            return
        }
        let oldHeight = newHeight - rows.height
        let oldRows = image == nil ? 0 : min(newPreviewHeight, max(1, oldHeight * newPreviewHeight / newHeight))
        // CoreGraphics counts y from the bottom: the history goes on top. The
        // history is squeezed again on every append, so it is resampled
        // without filtering - filtering would compound into a smear.
        if let image {
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: newPreviewHeight - oldRows, width: newWidth, height: oldRows))
            context.interpolationQuality = .medium
        }
        context.draw(rows, in: CGRect(x: 0, y: 0, width: newWidth, height: newPreviewHeight - oldRows))
        image = context.makeImage()
    }

    func image(maximumSize: CGSize) -> CGImage? {
        guard let image, maximumSize.width > 0, maximumSize.height > 0 else { return nil }
        let scale = min(1, maximumSize.width / CGFloat(image.width), maximumSize.height / CGFloat(image.height))
        guard scale < 1 else { return image }
        let outputWidth = max(1, Int((CGFloat(image.width) * scale).rounded(.down)))
        let outputHeight = max(1, Int((CGFloat(image.height) * scale).rounded(.down)))
        guard let context = Self.context(width: outputWidth, height: outputHeight) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage()
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        context?.interpolationQuality = .medium
        return context
    }
}

private struct RGBAFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let image: CGImage

    init(image: CGImage) throws {
        self.image = image
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { throw ScrollingCaptureError.incompatibleFrame }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw ScrollingCaptureError.incompatibleFrame }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = bytes
    }
}
