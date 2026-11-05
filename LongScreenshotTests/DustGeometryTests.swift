import CoreGraphics
import Foundation
import Testing
@testable import LongScreenshot

struct DustGeometryTests {
    // MARK: - Screen to layer

    @Test func layerFrameFlipsScreenCoordinatesOntoTheLayersTopLeftOrigin() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 100, y: 700, width: 200, height: 150)

        let frame = DustGeometry.layerFrame(for: rect, in: screen)

        #expect(frame == CGRect(x: 100, y: 50, width: 200, height: 150))
    }

    @Test func layerFrameIsRelativeToASecondaryScreensOwnOrigin() {
        // A display sitting to the right of and below the main one.
        let screen = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        let rect = CGRect(x: 1540, y: 700, width: 200, height: 150)

        let frame = DustGeometry.layerFrame(for: rect, in: screen)

        #expect(frame == CGRect(x: 100, y: 50, width: 200, height: 150))
    }

    // MARK: - Border strips

    @Test func borderStripsCoverEveryEdgeWithoutOverlapping() {
        let size = CGSize(width: 400, height: 300)

        let strips = DustGeometry.borderStrips(in: size, thickness: 5)

        #expect(strips == [
            CGRect(x: 0, y: 0, width: 400, height: 5),
            CGRect(x: 0, y: 295, width: 400, height: 5),
            CGRect(x: 0, y: 5, width: 5, height: 290),
            CGRect(x: 395, y: 5, width: 5, height: 290)
        ])

        let area = strips.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        let expectedArea: CGFloat = 400 * 5 * 2 + 5 * 290 * 2
        #expect(area == expectedArea)
        for (index, strip) in strips.enumerated() {
            for other in strips[(index + 1)...] {
                #expect(!strip.intersects(other))
            }
        }
    }

    @Test func borderStripsCostFarLessThanDissolvingTheWholeSelection() {
        let size = CGSize(width: 800, height: 600)

        let strips = DustGeometry.borderStrips(in: size)

        // One particle per point per axis. The whole rect would ask for 480k and
        // blow past the renderer's 400k ceiling, downsampling the visible edge.
        let stripParticles = strips.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        #expect(stripParticles < 400_000 / 10)
    }

    @Test func borderStripsClampThicknessOnATinySelection() {
        let strips = DustGeometry.borderStrips(in: CGSize(width: 8, height: 6), thickness: 5)

        #expect(!strips.isEmpty)
        for strip in strips {
            #expect(strip.minX >= 0)
            #expect(strip.minY >= 0)
            #expect(strip.maxX <= 8)
            #expect(strip.maxY <= 6)
        }
    }

    @Test func borderStripsDropTheVerticalPairWhenTheEdgesAlreadyMeet() {
        // Height exactly twice the thickness: the two horizontal strips already
        // cover everything, so adding zero-height verticals would be waste.
        let strips = DustGeometry.borderStrips(in: CGSize(width: 40, height: 10), thickness: 5)

        #expect(strips.count == 2)
    }

    @Test func borderStripsAreEmptyForADegenerateSize() {
        #expect(DustGeometry.borderStrips(in: .zero).isEmpty)
    }

    // MARK: - Shared sweep axis

    @Test func sweepBoundsSpanEveryPiece() {
        let frames = [
            CGRect(x: 100, y: 200, width: 50, height: 400),
            CGRect(x: 620, y: 480, width: 200, height: 240)
        ]

        #expect(DustSweep.bounds(of: frames) == CGRect(x: 100, y: 200, width: 720, height: 520))
    }

    @Test func sweepBoundsOfNothingAreEmpty() {
        #expect(DustSweep.bounds(of: []) == .zero)
    }

    @Test func sweepNormalizationPlacesPiecesOnOneTopDownAxis() {
        let bounds = CGRect(x: 0, y: 100, width: 800, height: 400)
        let top = CGRect(x: 0, y: 100, width: 10, height: 100)
        let bottom = CGRect(x: 0, y: 400, width: 10, height: 100)

        let topSweep = DustSweep.normalization(for: top, in: bounds)
        let bottomSweep = DustSweep.normalization(for: bottom, in: bounds)

        #expect(topSweep.start == 0)
        #expect(topSweep.span == 0.25)
        #expect(bottomSweep.start == 0.75)
        #expect(bottomSweep.span == 0.25)
        // The wave reaches the higher piece first - that is what makes separate
        // pieces crumble as one front instead of each sweeping itself.
        #expect(topSweep.start < bottomSweep.start)
    }

    @Test func sweepNormalizationOfASinglePieceCoversTheWholeAxis() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 240)

        let sweep = DustSweep.normalization(for: frame, in: DustSweep.bounds(of: [frame]))

        #expect(sweep.start == 0)
        #expect(sweep.span == 1)
    }

    @Test func sweepNormalizationOfAFlatGroupDegeneratesInsteadOfDividingByZero() {
        let flat = CGRect(x: 0, y: 50, width: 300, height: 0)

        let sweep = DustSweep.normalization(for: flat, in: flat)

        #expect(sweep.start == 0)
        #expect(sweep.span == 0)
    }

    // MARK: - Timing

    @Test func dissolveStaysShortEnoughToNotDelayTheDoneFeedback() {
        let settings = DustSettings()

        // The sweep, the slowest particle burning out, and a little slack.
        let expected: Float = 0.55 + 0.5 + 0.25
        #expect(abs(settings.phaseLifespan - expected) < 0.0001)
        #expect(settings.duration < 1.5)
    }

    @Test func durationShrinksAsSpeedRises() {
        var fast = DustSettings()
        fast.speed = 2

        #expect(fast.duration == DustSettings().duration / 2)
    }

    @Test func lifespanUsesTheLongerOfTheLifetimeBoundsWhenTheyAreInverted() {
        var inverted = DustSettings()
        inverted.minLifetime = 1.4
        inverted.maxLifetime = 0.2

        let expected: Float = 0.55 + 0.7 + 0.25
        #expect(abs(inverted.phaseLifespan - expected) < 0.0001)
    }
}
