import CoreGraphics
import Foundation
import Testing
@testable import LongScreenshot

@Suite(.serialized)
struct VisionVerticalOffsetEstimatorTests {
    private static let width = 96
    private static let viewportHeight = 120

    @Test func aConfirmedVisionOffsetIsKept() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 47))

        let offset = estimator.estimateDownwardOffset(
            from: page.frame(top: 47, height: Self.viewportHeight).image,
            to: page.frame(top: 0, height: Self.viewportHeight).image
        )

        #expect(offset == 47)
    }

    /// Vision can lock onto the wrong line of repetitive content with full
    /// confidence; the rows know better and must win.
    @Test func aVisionOffsetTheRowsContradictIsReplacedByTheRows() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 80))

        let offset = estimator.estimateDownwardOffset(
            from: page.frame(top: 47, height: Self.viewportHeight).image,
            to: page.frame(top: 0, height: Self.viewportHeight).image
        )

        #expect(offset == 47)
    }

    /// On a Retina screen every row of content is two rows of pixels. One row
    /// off, Vision's answer still lines up half the rows, too many to call
    /// it contradicted; the right offset lining up all of them must win.
    @Test func aVisionOffsetOneRetinaRowOffIsCorrected() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 49))

        let offset = estimator.estimateDownwardOffset(
            from: doubled(page.frame(top: 24, height: Self.viewportHeight / 2).image),
            to: doubled(page.frame(top: 0, height: Self.viewportHeight / 2).image)
        )

        #expect(offset == 48)
    }

    /// A sticky header or an animation changes some rows at the right offset;
    /// with nothing better on offer, Vision's answer must survive that.
    @Test func aVisionOffsetWithAFewChangedRowsIsKept() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 47))

        let offset = estimator.estimateDownwardOffset(
            from: withSolidBand(page.frame(top: 47, height: Self.viewportHeight).image, rows: 30),
            to: page.frame(top: 0, height: Self.viewportHeight).image
        )

        #expect(offset == 47)
    }

    /// A video or an animated banner in the overlap changes much more than a
    /// sticky header does, and not to one colour; half the overlap changing
    /// is still a scroll.
    @Test func aVisionOffsetWithHalfTheOverlapChangingIsKept() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 47))

        let offset = estimator.estimateDownwardOffset(
            from: withBand(
                from: page.frame(top: 400, height: Self.viewportHeight).image,
                over: page.frame(top: 47, height: Self.viewportHeight).image,
                rows: 36
            ),
            to: page.frame(top: 0, height: Self.viewportHeight).image
        )

        #expect(offset == 47)
    }

    /// On a blank page every offset lines up, so the rows cannot judge and
    /// Vision's answer stands, as it did before rows were consulted.
    @Test func aVisionOffsetTheRowsCannotJudgeIsKept() {
        let blank = solidImage(width: Self.width, height: Self.viewportHeight)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 30))

        #expect(estimator.estimateDownwardOffset(from: blank, to: blank) == 30)
    }

    /// Two lists laid out alike can fool Vision across a jump of the whole
    /// page: only the white between items lines up, and that is no scroll.
    @Test func aVisionOffsetOnlyTheBackgroundAgreesWithIsRejected() {
        let page = SyntheticPage(width: Self.width, height: 600, blankRowsPerItem: 16)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 48))

        // 312 rows down rather than 48: the white bands still line up at 48.
        let offset = estimator.estimateDownwardOffset(
            from: page.frame(top: 312, height: Self.viewportHeight).image,
            to: page.frame(top: 0, height: Self.viewportHeight).image
        )

        #expect(offset == nil)
    }

    @Test func aVisionOffsetOnAListPageIsKept() {
        let page = SyntheticPage(width: Self.width, height: 600, blankRowsPerItem: 16)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 48))

        let offset = estimator.estimateDownwardOffset(
            from: page.frame(top: 48, height: Self.viewportHeight).image,
            to: page.frame(top: 0, height: Self.viewportHeight).image
        )

        #expect(offset == 48)
    }

    /// A translucent window blurs the desktop behind it: the text scrolls
    /// while that backdrop stays put, so no row is ever pixel-for-pixel what
    /// it was. A scroll must still stand.
    @Test func aVisionOffsetOverATranslucentBackdropIsKept() {
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 47))

        let offset = estimator.estimateDownwardOffset(
            from: translucentFrame(top: 47),
            to: translucentFrame(top: 0)
        )

        #expect(offset == 47)
    }

    /// Over the same backdrop a jump elsewhere on the page lines up nothing
    /// but the gaps between lines, and is still no scroll.
    @Test func aJumpOverATranslucentBackdropIsRejected() {
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 48))

        let offset = estimator.estimateDownwardOffset(
            from: translucentFrame(top: 312),
            to: translucentFrame(top: 0)
        )

        #expect(offset == nil)
    }

    /// Captured surfaces often pad their rows; the signatures must step by the
    /// image's real stride rather than by its width.
    @Test func paddedRowsAreReadAtTheirRealStride() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let estimator = VisionVerticalOffsetEstimator(registrar: UnavailableTranslationRegistrar())

        let offset = estimator.estimateDownwardOffset(
            from: padded(page.frame(top: 47, height: Self.viewportHeight).image),
            to: padded(page.frame(top: 0, height: Self.viewportHeight).image)
        )

        #expect(offset == 47)
    }

    /// A cropped image hands out its parent's whole buffer; reading it as the
    /// crop's own pixels would compare the wrong rows.
    @Test func croppedImagesAreNotReadThroughTheirParentsBuffer() {
        let page = SyntheticPage(width: Self.width, height: 600)
        let whole = page.frame(top: 0, height: 600).image
        let estimator = VisionVerticalOffsetEstimator(registrar: UnavailableTranslationRegistrar())

        let offset = estimator.estimateDownwardOffset(
            from: whole.cropping(to: CGRect(x: 0, y: 147, width: Self.width, height: Self.viewportHeight))!,
            to: whole.cropping(to: CGRect(x: 0, y: 100, width: Self.width, height: Self.viewportHeight))!
        )

        #expect(offset == 47)
    }

    // MARK: - Helpers

    private func padded(_ image: CGImage) -> CGImage {
        let bytesPerRow = image.width * 4 + 64
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let result = context.makeImage()!
        precondition(result.bytesPerRow == bytesPerRow)
        return result
    }

    /// Paints the top `rows` rows of `image` one colour, like a sticky header.
    private func withSolidBand(_ image: CGImage, rows: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: image.height - rows, width: image.width, height: rows))
        return context.makeImage()!
    }

    /// Paints the top `rows` rows of `source` over the top of `image`, like a
    /// video playing there.
    private func withBand(from source: CGImage, over image: CGImage, rows: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let band = source.cropping(to: CGRect(x: 0, y: 0, width: source.width, height: rows))!
        context.draw(band, in: CGRect(x: 0, y: image.height - rows, width: image.width, height: rows))
        return context.makeImage()!
    }

    /// Stretches `image` to twice its height, each row drawn twice.
    private func doubled(_ image: CGImage) -> CGImage {
        let context = CGContext(
            data: nil, width: image.width, height: image.height * 2, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height * 2))
        return context.makeImage()!
    }

    /// Lines of text `top` rows down a page, over a backdrop that shades
    /// a little from top to bottom and left to right and does not scroll.
    private func translucentFrame(top: Int) -> CGImage {
        let width = Self.width
        let height = Self.viewportHeight
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let pageRow = top + row
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let isText = pageRow % SyntheticPage.itemHeight >= 8
                    && (pageRow &* 31 &+ column &* 17 &+ (pageRow / 3) &* column) % 5 == 0
                if isText {
                    bytes[offset] = UInt8(150 + pageRow % 100)
                    bytes[offset + 1] = UInt8(150 + (pageRow &* 7) % 100)
                    bytes[offset + 2] = 230
                } else {
                    bytes[offset] = UInt8(60 + row * 12 / height + column * 4 / width)
                    bytes[offset + 1] = UInt8(66 + row * 10 / height)
                    bytes[offset + 2] = UInt8(76 + column * 6 / width)
                }
            }
        }
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        return context.makeImage()!
    }

    private func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
