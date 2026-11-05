//
//  DustGeometry.swift
//  LongScreenshot
//

import CoreGraphics

/// Tunables for the dissolve. Deliberately not user-facing: the effect is a
/// one-off flourish, not a preference.
struct DustSettings {
    /// Multiplies both clocks below. 1 is the tuned speed.
    var speed: Float = 1
    /// Points per second squared, applied along `verticalDirection`.
    var gravity: Float = 120
    /// Width of the soft sweep window, as a fraction of the group's height.
    var waveWidth: Float = 0.4
    /// Seconds for the window to travel the whole group.
    var waveDuration: Float = 0.55
    /// Seconds a particle takes to fade once its lifetime runs out.
    var fadeDuration: Float = 0.28
    /// Dust rises like smoke rather than falling like debris.
    var driftsUp: Bool = true
    /// Particles per point along each axis.
    var density: Float = 1
    var minSpeed: Float = 42
    var maxSpeed: Float = 84
    var minLifetime: Float = 0.5
    var maxLifetime: Float = 1

    /// The physics clock runs faster than the sweep clock, which lets the wave
    /// take its time while the freed particles still scatter briskly.
    static let simulationSpeedMultiplier: Float = 2

    /// How far a particle's phase has to travel before the piece is spent. A
    /// piece's phase advances at `speed` times realtime, so this is in phase
    /// units, not seconds.
    var phaseLifespan: Float {
        waveDuration
            + max(maxLifetime, minLifetime) / Self.simulationSpeedMultiplier
            + 0.25
    }

    /// How long a dissolve stays on screen, in seconds.
    var duration: Float { phaseLifespan / max(speed, 0.0001) }
}

/// Pure geometry for the dissolve. Split out from the renderer and the panel so
/// the parts that are easy to get wrong can be tested without a GPU.
enum DustGeometry {
    /// Thickness of each slice cut out of the selection border, in points. The
    /// border stroke is 3pt wide; the extra point catches its antialiasing.
    static let borderStripThickness: CGFloat = 5

    /// Converts a rect in screen coordinates (y-up, origin at the bottom-left
    /// of the desktop) into the dust layer's space (y-down, origin at the
    /// top-left of `screenFrame`, points).
    static func layerFrame(for screenRect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenRect.minX - screenFrame.minX,
            y: screenFrame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    /// Cuts the selection border into four thin strips, in y-down points
    /// relative to the border view's bounds.
    ///
    /// The border is a stroked outline around an empty middle. Dissolving it as
    /// one rect would spend almost every particle on transparent pixels - a
    /// 800x600 selection alone would ask for 480k of them and blow past the
    /// renderer's ceiling, downsampling the part you can actually see. Four
    /// strips cost about 4% of that.
    ///
    /// The horizontal strips run the full width so they also cover the rounded
    /// corners; the vertical strips fill only the gap between them.
    static func borderStrips(
        in size: CGSize,
        thickness: CGFloat = borderStripThickness
    ) -> [CGRect] {
        let thickness = min(thickness, size.width / 2, size.height / 2)
        guard thickness > 0 else {
            return []
        }

        var strips = [
            CGRect(x: 0, y: 0, width: size.width, height: thickness),
            CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness)
        ]

        let middleHeight = size.height - thickness * 2
        if middleHeight > 0 {
            strips.append(CGRect(x: 0, y: thickness, width: thickness, height: middleHeight))
            strips.append(
                CGRect(
                    x: size.width - thickness,
                    y: thickness,
                    width: thickness,
                    height: middleHeight
                )
            )
        }
        return strips
    }
}

/// Places every piece of a dissolve on one shared vertical axis, so a single
/// wave front travels across all of them instead of each piece sweeping itself.
enum DustSweep {
    static func bounds(of frames: [CGRect]) -> CGRect {
        frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
    }

    /// Where `frame` starts on the axis and how much of it it spans, both
    /// normalized against `bounds`. A zero-height group degenerates to a single
    /// point at the top, which makes the whole group activate at once.
    static func normalization(
        for frame: CGRect,
        in bounds: CGRect
    ) -> (start: Float, span: Float) {
        guard bounds.height > 0 else {
            return (0, 0)
        }
        return (
            Float((frame.minY - bounds.minY) / bounds.height),
            Float(frame.height / bounds.height)
        )
    }
}
