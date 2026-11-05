import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LongScreenshot

struct ClothesLineThumbnailTests {
    @Test func aLongCaptureShowsTheTopOfThePageAtTheCardAspect() throws {
        // The top half is red and the bottom half blue, so the crop must be
        // all red if it really comes from the start of the page.
        let url = try writeTwoToneImage(width: 200, height: 4000)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumb = try #require(makeClothesLineThumbnail(url))

        #expect(thumb.width == 200)
        #expect(thumb.height == 300)
        let (red, blue) = try averageRedAndBlue(of: thumb)
        #expect(red > 240)
        #expect(blue < 15)
    }

    @Test func aWideCaptureIsOnlyDownsampled() throws {
        let url = try writeTwoToneImage(width: 1040, height: 260)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumb = try #require(makeClothesLineThumbnail(url))

        #expect(thumb.width == 520)
        #expect(thumb.height == 130)
    }

    @Test func anExtremelyLongCaptureStaysWithinThePixelBudget() throws {
        let url = try writeTwoToneImage(width: 1000, height: 100_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumb = try #require(makeClothesLineThumbnail(url))

        // sqrt(8M * 1000 / 100000) ≈ 283 pixels wide before cropping.
        #expect(thumb.width <= 290)
        #expect(thumb.width >= 270)
        #expect(abs(Double(thumb.height) / Double(thumb.width) - 1.5) < 0.02)
    }

    // MARK: - Fixture

    private func writeTwoToneImage(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Core Graphics puts y = 0 at the bottom, so blue fills the lower half.
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        let image = try #require(context.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClothesLineThumbnailTests-\(UUID().uuidString).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func averageRedAndBlue(of image: CGImage) throws -> (Double, Double) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0.0, blue = 0.0
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            red += Double(bytes[pixel])
            blue += Double(bytes[pixel + 2])
        }
        let count = Double(width * height)
        return (red / count, blue / count)
    }
}
