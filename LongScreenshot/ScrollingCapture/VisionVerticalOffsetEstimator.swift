//
//  VisionVerticalOffsetEstimator.swift
//  LongScreenshot
//

import CoreGraphics
import os
import Vision

nonisolated let stitchingLog = Logger(subsystem: "LongScreenshot", category: "stitching")

protocol VerticalOffsetEstimating {
    /// Returns the number of newly revealed rows after a verified downward scroll.
    func estimateDownwardOffset(from current: CGImage, to previous: CGImage) -> Int?
}

struct VisionVerticalOffsetEstimator: VerticalOffsetEstimating {
    private let maximumHorizontalMovement: CGFloat = 3
    private let minimumOverlapFraction: CGFloat = 0.15
    private let movementDeadZone: CGFloat = 3
    private let minimumConfidence: Float = 0.8
    private let registrar: any ImageTranslationRegistering

    init(registrar: any ImageTranslationRegistering = VisionImageTranslationRegistrar()) {
        self.registrar = registrar
    }

    func estimateDownwardOffset(from current: CGImage, to previous: CGImage) -> Int? {
        guard current.width == previous.width,
              current.height == previous.height,
              current.width >= 80,
              current.height >= 84 else {
            return nil
        }

        let rows = PixelRowOffsetEstimator(current: current, previous: previous)

        if let translation = registrar.translation(from: current, to: previous),
           isValid(translation, frameHeight: CGFloat(current.height)),
           translation.y > movementDeadZone {
            // Vision now and then reports high confidence for the wrong
            // offset: it locks onto the wrong line of repetitive content, or
            // matches two lists laid out alike across a jump of thousands of
            // points. Either stitches in a duplicated or missing band.
            let offset = Int(translation.y.rounded())
            let verified = rows.verify(offset)
            if verified != offset {
                stitchingLog.notice("Vision offset \(offset) overruled by rows: \(verified.map(String.init) ?? "frame skipped", privacy: .public)")
            }
            return verified
        }

        return rows.bestOffset()?.offset
    }

}

protocol ImageTranslationRegistering {
    func translation(from current: CGImage, to previous: CGImage) -> ImageTranslation?
}

struct VisionImageTranslationRegistrar: ImageTranslationRegistering {
    func translation(from current: CGImage, to previous: CGImage) -> ImageTranslation? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        let handler = VNImageRequestHandler(cgImage: current, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return ImageTranslation(
            x: observation.alignmentTransform.tx,
            y: observation.alignmentTransform.ty,
            confidence: observation.confidence
        )
    }
}

private extension VisionVerticalOffsetEstimator {
    private func isValid(
        _ translation: ImageTranslation,
        frameHeight: CGFloat
    ) -> Bool {
        let maximumVerticalMovement = frameHeight * (1 - minimumOverlapFraction)
        return translation.confidence >= minimumConfidence
            && abs(translation.x) <= maximumHorizontalMovement
            && abs(translation.y) <= maximumVerticalMovement
    }

}

struct ImageTranslation {
    let x: CGFloat
    let y: CGFloat
    let confidence: Float
}

/// Compares frames by row signatures: a hash of a few dozen pixels sampled
/// across each row. Scrolling moves whole rows, so the rows of the previous
/// frame reappear `offset` rows higher in the current one.
private struct PixelRowOffsetEstimator {
    private static let sampledColumns = 32
    /// How far a sampled channel may drift and still be the same row. Text
    /// over a translucent window scrolls past a backdrop that stays put, so
    /// its background shades a little from one row to the next.
    private static let tolerance: UInt8 = 24
    private let current: [UInt64]?
    private let previous: [UInt64]?
    private let currentPixels: [UInt8]
    private let previousPixels: [UInt8]

    private let sampleCount = 24
    private let minimumMatches = 18
    private let minimumDistinctMatches = 6

    init(current: CGImage, previous: CGImage) {
        let current = Self.sampledPixels(for: current)
        let previous = Self.sampledPixels(for: previous)
        self.current = current.map(Self.rowSignatures)
        self.previous = previous.map(Self.rowSignatures)
        currentPixels = current ?? []
        previousPixels = previous ?? []
    }

    /// Checks an offset found some other way. The rows have the final say only
    /// when they make a clear case: a sticky header or a video can knock rows
    /// out at the right offset, so a slightly better match elsewhere is not
    /// enough. Returns `candidate` if it stands, the rows' own offset if it
    /// does not, or nil if it does not and the rows have nothing better.
    func verify(_ candidate: Int) -> Int? {
        guard let current, let previous,
              current.count == previous.count,
              candidate > 0, candidate < current.count else {
            return candidate
        }
        if isContradicted(candidate, current: current, previous: previous) {
            return bestOffset()?.offset
        }
        let candidateMatches = matches(at: candidate, current: current, previous: previous).count
        guard candidateMatches < minimumMatches,
              let best = bestOffset(),
              best.matches >= candidateMatches + sampleCount / 3 else {
            return candidate
        }
        return best.offset
    }

    /// Whether the frame has enough different rows to judge by, yet hardly any
    /// of them line up at `offset`. A frame from somewhere else on the page
    /// matches background at best; a scroll keeps at least a third. Rows are
    /// compared within `tolerance` here: over a translucent backdrop not one
    /// of them is exactly what it was, and a scroll is no less a scroll.
    private func isContradicted(_ offset: Int, current: [UInt64], previous: [UInt64]) -> Bool {
        let overlap = current.count - offset
        var present: [Int] = []
        var matched: [Int] = []
        for sample in 1...sampleCount {
            let row = sample * overlap / (sampleCount + 1)
            let isNew = !present.contains { isAlike(currentPixels, row, currentPixels, $0) }
            if isNew {
                present.append(row)
            }
            if isAlike(currentPixels, row, previousPixels, row + offset),
               !matched.contains(where: { isAlike(currentPixels, row, currentPixels, $0) }) {
                matched.append(row)
            }
        }
        return present.count >= minimumDistinctMatches && matched.count * 3 < present.count
    }

    private func isAlike(_ pixels: [UInt8], _ row: Int, _ otherPixels: [UInt8], _ otherRow: Int) -> Bool {
        let bytesPerRow = Self.sampledColumns * 4
        let start = row * bytesPerRow
        let otherStart = otherRow * bytesPerRow
        for index in 0..<bytesPerRow {
            let a = pixels[start + index]
            let b = otherPixels[otherStart + index]
            if (a > b ? a - b : b - a) > Self.tolerance {
                return false
            }
        }
        return true
    }

    func bestOffset() -> (offset: Int, matches: Int)? {
        guard let current, let previous, current.count == previous.count else {
            return nil
        }

        let height = current.count
        let minimumOffset = max(4, height / 10)
        let maximumOffset = height - max(2, Int((CGFloat(height) * 0.15).rounded(.up)))
        guard minimumOffset <= maximumOffset else {
            return nil
        }

        var bestOffset: Int?
        var bestMatchCount = 0
        for offset in minimumOffset...maximumOffset {
            let (count, distinct) = matches(at: offset, current: current, previous: previous)
            guard count >= minimumMatches,
                  distinct >= minimumDistinctMatches,
                  count > bestMatchCount else {
                continue
            }
            bestOffset = offset
            bestMatchCount = count
        }
        return bestOffset.map { ($0, bestMatchCount) }
    }

    /// How many sampled rows line up at `offset`, and how many different rows
    /// those were - a blank page lines up everywhere, so matches alone prove
    /// nothing. Distinct is only counted up to the minimum it is checked
    /// against.
    private func matches(
        at offset: Int,
        current: [UInt64],
        previous: [UInt64]
    ) -> (count: Int, distinct: Int) {
        let overlap = current.count - offset
        return current.withUnsafeBufferPointer { current in
            previous.withUnsafeBufferPointer { previous in
                var count = 0
                var distinct: [UInt64] = []
                distinct.reserveCapacity(minimumDistinctMatches)
                for sample in 1...sampleCount {
                    let row = sample * overlap / (sampleCount + 1)
                    let signature = current[row]
                    guard signature == previous[row + offset] else {
                        continue
                    }
                    count += 1
                    if distinct.count < minimumDistinctMatches, !distinct.contains(signature) {
                        distinct.append(signature)
                    }
                }
                return (count, distinct.count)
            }
        }
    }

    /// Lets CoreGraphics pick the sampled columns: drawing at full height into
    /// a context only `sampledColumns` wide, without interpolation, keeps every
    /// row intact and reads one pixel per column. That is system code, so it
    /// stays fast in a Debug build, and it reads cropped or padded images the
    /// same way any other draw would.
    private static func sampledPixels(for image: CGImage) -> [UInt8]? {
        let height = image.height
        let bytesPerRow = sampledColumns * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampledColumns,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampledColumns, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func rowSignatures(for pixels: [UInt8]) -> [UInt64] {
        let bytesPerRow = sampledColumns * 4
        let height = pixels.count / bytesPerRow
        return pixels.withUnsafeBytes { buffer in
            [UInt64](unsafeUninitializedCapacity: height) { rows, initializedCount in
                for row in 0..<height {
                    var hash: UInt64 = 1_469_598_103_934_665_603
                    for column in 0..<sampledColumns {
                        let pixel = buffer.loadUnaligned(fromByteOffset: row * bytesPerRow + column * 4, as: UInt32.self)
                        hash ^= UInt64(pixel)
                        hash &*= 1_099_511_628_211
                    }
                    rows[row] = hash
                }
                initializedCount = height
            }
        }
    }
}
