import CoreGraphics
import Foundation
import Testing
@testable import LongScreenshot

struct ScrollingCaptureChromeLayoutTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private static let card = CGSize(width: 200, height: 240)
    private static let controls = CGSize(width: 184, height: 32)

    private static func previewOrigin(for selection: CGRect) -> CGPoint {
        ScrollingCaptureChromeLayout.origin(
            for: card, around: selection, in: screen, gap: 12,
            preferring: [.right, .left, .below, .above]
        )
    }

    private static func controlsOrigin(for selection: CGRect) -> CGPoint {
        ScrollingCaptureChromeLayout.origin(
            for: controls, around: selection, in: screen, gap: 16,
            preferring: [.below, .above, .right, .left]
        )
    }

    private static func rect(_ origin: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(origin: origin, size: size)
    }

    // MARK: - The common case is unchanged

    @Test func theCardSitsOffTheSelectionsRightEdgeWhenThereIsRoom() {
        let selection = CGRect(x: 400, y: 300, width: 600, height: 500)

        let origin = Self.previewOrigin(for: selection)

        // Right of the selection, top-aligned with it - where it has always been.
        #expect(origin == CGPoint(x: 1012, y: 560))
        #expect(!Self.rect(origin, Self.card).intersects(selection))
    }

    @Test func theControlsSitUnderTheSelectionWhenThereIsRoom() {
        let selection = CGRect(x: 400, y: 300, width: 600, height: 500)

        let origin = Self.controlsOrigin(for: selection)

        #expect(origin == CGPoint(x: 608, y: 252))
        #expect(!Self.rect(origin, Self.controls).intersects(selection))
    }

    // MARK: - The cases that used to clamp on top of the selection

    @Test func theCardFlipsToTheLeftWhenTheSelectionHugsTheRightEdge() {
        let selection = CGRect(x: 400, y: 300, width: 1300, height: 500)

        let origin = Self.previewOrigin(for: selection)

        #expect(origin.x < selection.minX)
        #expect(!Self.rect(origin, Self.card).intersects(selection))
    }

    @Test func aSelectionTooWideForEitherSideSendsTheCardBelowInsteadOfOverIt() {
        // 1600 of 1728 points wide: neither side has 200 points to spare, which
        // is exactly the case the old clamp resolved by covering the content.
        let selection = CGRect(x: 64, y: 300, width: 1600, height: 400)

        let origin = Self.previewOrigin(for: selection)

        #expect(!Self.rect(origin, Self.card).intersects(selection))
        #expect(Self.screen.contains(Self.rect(origin, Self.card)))
    }

    @Test func aSelectionRunningToTheBottomPushesTheControlsAboveIt() {
        let selection = CGRect(x: 400, y: 0, width: 600, height: 600)

        let origin = Self.controlsOrigin(for: selection)

        #expect(origin.y > selection.maxY - Self.controls.height)
        #expect(!Self.rect(origin, Self.controls).intersects(selection))
    }

    @Test func chromeStaysOnScreenForEverySelectionItCanBeGiven() {
        let selections = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 1628, y: 1017, width: 100, height: 100),
            CGRect(x: 64, y: 300, width: 1600, height: 400),
            CGRect(x: 400, y: 0, width: 600, height: 1117),
            CGRect(x: 0, y: 0, width: 1728, height: 1117)
        ]

        for selection in selections {
            for (origin, size) in [
                (Self.previewOrigin(for: selection), Self.card),
                (Self.controlsOrigin(for: selection), Self.controls)
            ] {
                #expect(
                    Self.screen.insetBy(dx: -0.01, dy: -0.01).contains(Self.rect(origin, size)),
                    "\(Self.rect(origin, size)) escaped the screen for selection \(selection)"
                )
            }
        }
    }

    // MARK: - Degenerate case

    @Test func aFullScreenSelectionTakesTheSmallestBiteRatherThanGivingUp() {
        // Nothing can clear a selection that is the whole display, so the rule
        // becomes "cover as little of it as possible" instead of "cover the
        // middle of it", which is what clamping used to do.
        let selection = Self.screen

        let origin = Self.previewOrigin(for: selection)
        let covered = Self.rect(origin, Self.card).intersection(selection)

        #expect(Self.screen.contains(Self.rect(origin, Self.card)))
        #expect(covered.width * covered.height <= Self.card.width * Self.card.height)
    }

    @Test func noPreferredSidesFallsBackToTheScreenCornerInsteadOfCrashing() {
        let origin = ScrollingCaptureChromeLayout.origin(
            for: Self.card, around: Self.screen, in: Self.screen, gap: 12, preferring: []
        )

        #expect(origin == CGPoint(x: 8, y: 8))
    }
}

struct ScrollingCaptureButtonWidthTests {
    @Test func shortTitlesKeepTheOriginalButtonWidth() {
        // "Cancel" measures about 46.2pt at 14pt semibold - just under the 48pt
        // that the 88pt minimum leaves for a title.
        #expect(ScrollingCaptureChromeLayout.buttonWidth(fittingTitleWidths: [46.2, 36]) == 88)
    }

    @Test func aLongTitleWidensTheWholeGroup() {
        // A long translation sets the width for every button beside it, with
        // the title inset kept on both sides.
        #expect(ScrollingCaptureChromeLayout.buttonWidth(fittingTitleWidths: [30, 70.2]) == 111)
    }

    @Test func noTitlesFallsBackToTheMinimum() {
        #expect(ScrollingCaptureChromeLayout.buttonWidth(fittingTitleWidths: []) == 88)
    }
}

struct ScrollingCaptureLocalizationTests {
    /// Asks for English explicitly, so the check holds whatever language the
    /// machine running the tests is set to. The resource's locale picks the
    /// translation; `String(localized:locale:)` would only format with it.
    private static func english(_ value: String.LocalizationValue) -> String {
        String(localized: LocalizedStringResource(value, locale: Locale(identifier: "en")))
    }

    @Test func theSectionCountIsSingularForOneSection() {
        #expect(Self.english("\(1) sections • \(480) px") == "1 section • 480 px")
    }

    @Test func theSectionCountIsPluralOtherwise() {
        #expect(Self.english("\(3) sections • \(1440) px") == "3 sections • 1,440 px")
    }
}
