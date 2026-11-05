import CoreGraphics
import Foundation
@testable import LongScreenshot

/// A tall page whose every row is visually distinct, so both the row-signature
/// estimator and the assertions can identify rows unambiguously.
struct SyntheticPage {
    /// Rows are grouped into items this tall, like the entries of a list.
    static let itemHeight = 24

    let width: Int
    let height: Int
    private let pixels: [UInt8]

    /// `blankRowsPerItem` white rows open every item, as the gaps do between
    /// the entries of a list; the white rows are all alike.
    init(width: Int, height: Int, blankRowsPerItem: Int = 0) {
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height where row % Self.itemHeight >= blankRowsPerItem {
            let identifier = UInt8(truncatingIfNeeded: row)
            for column in 0..<width {
                let offset = (row * width + column) * 4
                bytes[offset] = identifier
                bytes[offset + 1] = UInt8(truncatingIfNeeded: row &* 7 &+ column)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: row &* 13)
                bytes[offset + 3] = 255
            }
        }
        pixels = bytes
    }

    /// The identity byte stored in the red channel of every pixel on a row.
    func rowIdentifiers(from top: Int, count: Int) -> [UInt8] {
        (top..<(top + count)).map { UInt8(truncatingIfNeeded: $0) }
    }

    /// The raw RGBA bytes of `count` rows from `top`.
    func pixels(from top: Int, count: Int) -> Data {
        Data(pixels[(top * width * 4)..<((top + count) * width * 4)])
    }

    func frame(top: Int, height frameHeight: Int) -> ScrollingCaptureFrame {
        let start = top * width * 4
        let end = (top + frameHeight) * width * 4
        let data = Data(pixels[start..<end])
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(
            width: width,
            height: frameHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return ScrollingCaptureFrame(image: image)
    }
}

/// Hands back a predetermined sequence of scroll distances.
final class ScriptedOffsetEstimator: VerticalOffsetEstimating {
    private var offsets: [Int]

    init(offsets: [Int]) {
        self.offsets = offsets
    }

    func estimateDownwardOffset(from current: CGImage, to previous: CGImage) -> Int? {
        offsets.isEmpty ? nil : offsets.removeFirst()
    }
}

struct UnavailableTranslationRegistrar: ImageTranslationRegistering {
    func translation(from current: CGImage, to previous: CGImage) -> ImageTranslation? { nil }
}

/// A registrar that always reports the same confident translation.
struct FixedTranslationRegistrar: ImageTranslationRegistering {
    let y: CGFloat

    func translation(from current: CGImage, to previous: CGImage) -> ImageTranslation? {
        ImageTranslation(x: 0, y: y, confidence: 1)
    }
}
