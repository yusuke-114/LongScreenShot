import CoreGraphics
import Foundation
import Testing
@testable import LongScreenshot

/// Feeds a synthetic scroll through the stitcher and checks the assembled
/// artifact is a byte-exact prefix of the page that was "scrolled".
@Suite(.serialized)
struct ScrollingImageStitcherTests {
    private static let width = 96
    private static let viewportHeight = 120

    @Test func stitchingASyntheticScrollReproducesTheSourcePage() throws {
        let page = SyntheticPage(width: Self.width, height: 600)
        let offsets = [40, 55, 18, 92, 33]
        var stitcher = ScrollingImageStitcher(
            maximumHeight: 30_000,
            offsetEstimator: ScriptedOffsetEstimator(offsets: offsets)
        )

        var top = 0
        let firstResult = try stitcher.append(page.frame(top: top, height: Self.viewportHeight))
        #expect(firstResult == .started)
        for offset in offsets {
            top += offset
            let result = try stitcher.append(page.frame(top: top, height: Self.viewportHeight))
            #expect(result == .appended(addedHeight: offset))
        }

        let taken = stitcher.takeArtifact()
        let artifact = try #require(taken)
        defer { artifact.removeTemporaryFiles() }

        let expectedHeight = Self.viewportHeight + offsets.reduce(0, +)
        #expect(artifact.width == Self.width)
        #expect(artifact.height == expectedHeight)
        #expect(try rows(of: artifact) == page.rowIdentifiers(from: 0, count: expectedHeight))
    }

    @Test func pixelFallbackRecoversTheRealScrollDistanceWithoutVision() throws {
        let page = SyntheticPage(width: Self.width, height: 600)
        // A registrar that never aligns forces the row-signature fallback.
        let estimator = VisionVerticalOffsetEstimator(registrar: UnavailableTranslationRegistrar())
        var stitcher = ScrollingImageStitcher(maximumHeight: 30_000, offsetEstimator: estimator)

        let firstResult0 = try stitcher.append(page.frame(top: 0, height: Self.viewportHeight))
        #expect(firstResult0 == .started)
        let secondResult = try stitcher.append(page.frame(top: 47, height: Self.viewportHeight))
        #expect(secondResult == .appended(addedHeight: 47))

        let taken = stitcher.takeArtifact()
        let artifact = try #require(taken)
        defer { artifact.removeTemporaryFiles() }
        #expect(artifact.height == Self.viewportHeight + 47)
        #expect(
            try rows(of: artifact)
                == page.rowIdentifiers(from: 0, count: Self.viewportHeight + 47)
        )
    }

    @Test func framesThatDidNotScrollFarEnoughAreIgnored() throws {
        let page = SyntheticPage(width: Self.width, height: 600)
        var stitcher = ScrollingImageStitcher(
            maximumHeight: 30_000,
            // Below the one-tenth-of-a-viewport floor the stitcher requires.
            offsetEstimator: ScriptedOffsetEstimator(offsets: [5])
        )

        let firstResult0 = try stitcher.append(page.frame(top: 0, height: Self.viewportHeight))
        #expect(firstResult0 == .started)
        let smallScroll = try stitcher.append(page.frame(top: 5, height: Self.viewportHeight))
        #expect(smallScroll == .ignored)

        let taken = stitcher.takeArtifact()
        let artifact = try #require(taken)
        defer { artifact.removeTemporaryFiles() }
        #expect(artifact.height == Self.viewportHeight)
    }

    @Test func framesWithoutAMeasurableOffsetAreIgnored() throws {
        let page = SyntheticPage(width: Self.width, height: 600)
        var stitcher = ScrollingImageStitcher(
            maximumHeight: 30_000,
            offsetEstimator: ScriptedOffsetEstimator(offsets: [])
        )

        let firstResult0 = try stitcher.append(page.frame(top: 0, height: Self.viewportHeight))
        #expect(firstResult0 == .started)
        let unmeasurable = try stitcher.append(page.frame(top: 60, height: Self.viewportHeight))
        #expect(unmeasurable == .ignored)

        let taken = stitcher.takeArtifact()
        let artifact = try #require(taken)
        defer { artifact.removeTemporaryFiles() }
        #expect(artifact.height == Self.viewportHeight)
    }

    /// The App Store bug: a frame from thousands of points up the page, whose
    /// list Vision mistook for the one it had just seen, was stitched on and
    /// the page repeated from there. It must be skipped, and the capture carry
    /// on from the last frame that really followed.
    @Test func aFrameFromElsewhereOnThePageIsNotStitchedOn() throws {
        let page = SyntheticPage(width: Self.width, height: 900, blankRowsPerItem: 16)
        let estimator = VisionVerticalOffsetEstimator(registrar: FixedTranslationRegistrar(y: 48))
        var stitcher = ScrollingImageStitcher(maximumHeight: 30_000, offsetEstimator: estimator)

        #expect(try stitcher.append(page.frame(top: 0, height: Self.viewportHeight)) == .started)
        #expect(try stitcher.append(page.frame(top: 48, height: Self.viewportHeight)) == .appended(addedHeight: 48))
        // Lines up with the last frame's list at 48, but sits 312 rows on.
        #expect(try stitcher.append(page.frame(top: 360, height: Self.viewportHeight)) == .ignored)
        #expect(try stitcher.append(page.frame(top: 96, height: Self.viewportHeight)) == .appended(addedHeight: 48))

        let taken = stitcher.takeArtifact()
        let artifact = try #require(taken)
        defer { artifact.removeTemporaryFiles() }
        let expectedHeight = Self.viewportHeight + 96
        #expect(artifact.height == expectedHeight)
        #expect(try pixels(of: artifact) == page.pixels(from: 0, count: expectedHeight))
    }

    // MARK: - Helpers

    private func pixels(of artifact: ScrollingCaptureArtifact) throws -> Data {
        try artifact.tiles.reduce(into: Data()) { $0.append(try Data(contentsOf: $1.url)) }
    }

    /// Reads back the per-row identity byte the synthetic page encodes.
    private func rows(of artifact: ScrollingCaptureArtifact) throws -> [UInt8] {
        var identifiers: [UInt8] = []
        for tile in artifact.tiles {
            let bytes = try Data(contentsOf: tile.url)
            for row in 0..<tile.height {
                identifiers.append(bytes[row * artifact.width * 4])
            }
        }
        return identifiers
    }
}
