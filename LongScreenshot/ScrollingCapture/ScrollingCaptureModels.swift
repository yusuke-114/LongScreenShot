//
//  ScrollingCaptureModels.swift
//  LongScreenshot
//

import CoreGraphics
import Foundation

struct ScrollingCaptureFrame {
    let image: CGImage
}

struct ScrollingCaptureSelection: Equatable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let backingScale: CGFloat

    var pixelSize: CGSize {
        CGSize(
            width: (sourceRect.width * backingScale).rounded(),
            height: (sourceRect.height * backingScale).rounded()
        )
    }
}

enum ScrollingCapturePhase: Equatable {
    case idle
    case capturing
    case processing
    case finished
}

enum ScrollingImageAppendResult: Equatable {
    case started
    case appended(addedHeight: Int)
    case ignored
}

enum ScrollingCaptureGuidance: Equatable {
    case scrollDownSlowly
    case capturedContent
}

enum ScrollingCaptureProcessingTipLayout {
    static let closeButtonDelay: TimeInterval = 2

    static func panelFrame(size: CGSize, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func shouldShowCloseButton(after elapsed: TimeInterval) -> Bool {
        elapsed >= closeButtonDelay
    }
}

enum ScrollingCaptureError: LocalizedError, Equatable {
    case maximumHeightReached
    case scrollingTooFast
    case incompatibleFrame
    case permissionDenied
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .maximumHeightReached:
            String(localized: "The scrolling screenshot reached its maximum height.")
        case .scrollingTooFast:
            String(localized: "Scrolling too fast. Slow down and keep each new frame overlapping the previous one.")
        case .incompatibleFrame:
            String(localized: "The captured frame does not match the selected area.")
        case .permissionDenied:
            String(localized: "Screen Recording permission is required to capture a scrolling screenshot.")
        case .captureFailed(let message):
            message
        }
    }
}
