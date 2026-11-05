//
//  ScrollingCaptureChromeLayout.swift
//  LongScreenshot
//

import CoreGraphics

/// Places the capture chrome around the selection without ever landing on top
/// of it.
///
/// Overlapping used to be invisible: the panels are excluded from screen
/// capture, so a preview card clamped over the selection never showed up in the
/// exported image. It still hid the content the user was trying to scroll, and
/// the moment overlays become recordable it is baked into every frame.
enum ScrollingCaptureChromeLayout {
    enum Side {
        case right
        case left
        case above
        case below
    }

    /// Distance kept from the screen edge.
    static let screenMargin: CGFloat = 8

    /// Glass text buttons never get narrower than this, so short titles keep
    /// the size they have always had.
    static let minimumButtonWidth: CGFloat = 88

    /// Space left on each side of a glass button's title.
    static let buttonTitleInset: CGFloat = 20

    /// The width every button in a group shares: wide enough for the longest
    /// title, so a long translation grows the buttons instead of clipping.
    static func buttonWidth(fittingTitleWidths titleWidths: [CGFloat]) -> CGFloat {
        max(minimumButtonWidth, ceil((titleWidths.max() ?? 0) + buttonTitleInset * 2))
    }

    /// The first placement in `sides` that fits on screen without touching
    /// `selection`.
    ///
    /// When the selection is large enough that no placement clears it - it
    /// fills the display - the one covering the least of it wins, because
    /// something has to give and the smallest bite is the right one to take.
    static func origin(
        for size: CGSize,
        around selection: CGRect,
        in screenFrame: CGRect,
        gap: CGFloat,
        preferring sides: [Side]
    ) -> CGPoint {
        let candidates = sides.map { side in
            clamped(
                candidate(side, size: size, selection: selection, gap: gap),
                size: size,
                in: screenFrame
            )
        }
        guard !candidates.isEmpty else {
            return CGPoint(x: screenFrame.minX + screenMargin, y: screenFrame.minY + screenMargin)
        }

        if let clear = candidates.first(where: {
            !CGRect(origin: $0, size: size).intersects(selection)
        }) {
            return clear
        }
        return candidates.min {
            overlap($0, size, selection) < overlap($1, size, selection)
        } ?? candidates[0]
    }

    private static func candidate(
        _ side: Side,
        size: CGSize,
        selection: CGRect,
        gap: CGFloat
    ) -> CGPoint {
        switch side {
        case .right:
            CGPoint(x: selection.maxX + gap, y: selection.maxY - size.height)
        case .left:
            CGPoint(x: selection.minX - size.width - gap, y: selection.maxY - size.height)
        case .above:
            CGPoint(x: selection.midX - size.width / 2, y: selection.maxY + gap)
        case .below:
            CGPoint(x: selection.midX - size.width / 2, y: selection.minY - size.height - gap)
        }
    }

    private static func clamped(_ origin: CGPoint, size: CGSize, in screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(
                max(origin.x, screenFrame.minX + screenMargin),
                screenFrame.maxX - size.width - screenMargin
            ),
            y: min(
                max(origin.y, screenFrame.minY + screenMargin),
                screenFrame.maxY - size.height - screenMargin
            )
        )
    }

    private static func overlap(_ origin: CGPoint, _ size: CGSize, _ selection: CGRect) -> CGFloat {
        let rect = CGRect(origin: origin, size: size).intersection(selection)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}
