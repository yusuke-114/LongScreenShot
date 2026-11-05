//
//  ScrollingCaptureStore.swift
//  LongScreenshot
//

import CoreGraphics
import Foundation
import Observation

@MainActor
protocol ScreenRegionCapturing: AnyObject {
    func requestPermission() -> Bool
    func startCapture(
        selection: ScrollingCaptureSelection,
        onFrame: @escaping (ScrollingCaptureFrame) -> Void
    ) async throws
    func captureFrame() async throws -> ScrollingCaptureFrame?
    func stopCapture()
}

@MainActor
@Observable
final class ScrollingCaptureStore {
    /// How long after a scroll event the next frame is taken. Consecutive
    /// frames must still overlap by 15% to stitch, so this caps how fast the
    /// user can scroll: at 150ms a quick trackpad flick outran it. Frames take
    /// about 35-45ms to process, so 50ms still leaves the stitcher room, and
    /// the stream only refreshes every 33ms anyway.
    private static let manualCaptureDelay: Duration = .milliseconds(50)
    private let captureService: any ScreenRegionCapturing
    private let maximumHeightOverride: Int?
    private let processor: ScrollingCaptureProcessor
    private var lastAcceptedFrameFingerprint: UInt64?
    private var lastIgnoredFrameFingerprint: UInt64?
    private var consecutiveChangedIgnoredFrames = 0
    private var completedSnapshot: ScrollingCaptureArtifact?
    private var isManualCapturePending = false
    private var isManualCaptureInFlight = false
    private var queuedScrollActivity = false
    private var outstandingFrameCount = 0

    private(set) var phase: ScrollingCapturePhase = .idle
    private(set) var message: String?
    private(set) var capturedFrameCount = 0
    private(set) var capturedHeight = 0
    private(set) var captureGuidance: ScrollingCaptureGuidance = .scrollDownSlowly
    var onProgressChanged: ((ScrollingCaptureGuidance, Int, Int) -> Void)?
    var onPreviewChanged: ((CGImage) -> Void)?
    var onMaximumHeightReached: ((ScrollingCaptureArtifact) -> Void)?

    init(
        captureService: any ScreenRegionCapturing,
        maximumHeight: Int? = nil,
        maximumPendingFrameCount: Int = 2,
        processingQueue: DispatchQueue? = nil,
        offsetEstimator: (any VerticalOffsetEstimating)? = nil
    ) {
        self.captureService = captureService
        maximumHeightOverride = maximumHeight
        let resolvedOffsetEstimator = offsetEstimator ?? VisionVerticalOffsetEstimator()
        processor = ScrollingCaptureProcessor(
            maximumHeight: maximumHeight ?? ScrollingCaptureHeightLimit.maximumHeight,
            maximumPendingFrameCount: maximumPendingFrameCount,
            processingQueue: processingQueue,
            offsetEstimator: resolvedOffsetEstimator
        )
        processor.onUpdate = { [weak self] update in
            self?.apply(update)
        }
    }

    func beginCapture(selection: ScrollingCaptureSelection) async throws {
        guard captureService.requestPermission() else {
            phase = .idle
            message = ScrollingCaptureError.permissionDenied.errorDescription
            throw ScrollingCaptureError.permissionDenied
        }

        let maximumHeight = maximumCaptureHeight
        guard Int(selection.pixelSize.height) <= maximumHeight else {
            phase = .idle
            message = ScrollingCaptureError.maximumHeightReached.errorDescription
            throw ScrollingCaptureError.maximumHeightReached
        }

        processor.start(maximumHeight: maximumHeight)
        completedSnapshot = nil
        message = nil
        capturedFrameCount = 0
        capturedHeight = 0
        captureGuidance = .scrollDownSlowly
        outstandingFrameCount = 0
        resetCaptureFeedback()
        phase = .capturing
        notifyProgressChanged()

        do {
            try await captureService.startCapture(selection: selection) { [weak self] frame in
                self?.append(frame)
            }
        } catch {
            phase = .idle
            message = error.localizedDescription
            throw error
        }
    }

    func finishCapture(completion: @escaping (ScrollingCaptureArtifact?) -> Void) {
        if phase == .finished {
            completion(completedSnapshot)
            return
        }

        guard phase == .capturing else {
            completion(nil)
            return
        }

        captureService.stopCapture()
        phase = .processing
        processor.finish { [weak self] snapshot in
            guard let self else {
                return
            }
            self.completedSnapshot = snapshot
            guard let snapshot else {
                self.phase = .idle
                self.message = String(localized: "Scroll the selected area before finishing the capture.")
                completion(nil)
                return
            }
            completion(snapshot)
        }
    }

    func captureAfterScrollActivity() {
        guard phase == .capturing else {
            return
        }

        if isManualCaptureInFlight {
            queuedScrollActivity = true
            return
        }

        if outstandingFrameCount >= 2 {
            queuedScrollActivity = true
            return
        }

        guard !isManualCapturePending else {
            return
        }

        scheduleManualCapture()
    }

    private func scheduleManualCapture() {
        isManualCapturePending = true
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.manualCaptureDelay)
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.isManualCapturePending = false
            guard self.phase == .capturing else {
                return
            }
            self.isManualCaptureInFlight = true
            defer {
                self.isManualCaptureInFlight = false
                self.resumeCaptureAfterProcessingIfNeeded()
            }

            guard let frame = try? await self.captureService.captureFrame() else {
                return
            }
            self.append(frame)
        }
    }

    func completeExport(message: String) {
        guard phase == .processing || phase == .finished else {
            return
        }
        phase = .finished
        self.message = message
        completedSnapshot = nil
    }

    func cancelCapture() {
        captureService.stopCapture()
        isManualCapturePending = false
        isManualCaptureInFlight = false
        queuedScrollActivity = false
        outstandingFrameCount = 0
        processor.cancel()
        message = nil
        capturedFrameCount = 0
        capturedHeight = 0
        captureGuidance = .scrollDownSlowly
        resetCaptureFeedback()
        completedSnapshot = nil
        phase = .idle
        notifyProgressChanged()
    }

    private func append(_ frame: ScrollingCaptureFrame) {
        guard phase == .capturing else {
            return
        }

        outstandingFrameCount += 1
        processor.enqueue(frame)
    }

    private func apply(_ update: Result<ScrollingCaptureProcessor.Update, Error>) {
        guard phase == .capturing || phase == .processing else {
            return
        }
        defer {
            outstandingFrameCount = max(0, outstandingFrameCount - 1)
            resumeCaptureAfterProcessingIfNeeded()
        }

        switch update {
        case .success(let update):
            switch update.result {
            case .started:
                capturedFrameCount = 1
                capturedHeight = update.frameHeight
                captureGuidance = .scrollDownSlowly
                recordAcceptedFrame(update.fingerprint)
                publishPreview(update.preview)
                notifyProgressChanged()
            case .appended(let addedHeight):
                capturedFrameCount += 1
                capturedHeight += addedHeight
                captureGuidance = .capturedContent
                recordAcceptedFrame(update.fingerprint)
                publishPreview(update.preview)
                notifyProgressChanged()
            case .ignored:
                recordIgnoredFrame(update.fingerprint)
            }
        case .failure(let error):
            guard phase == .capturing else {
                return
            }

            if let error = error as? ScrollingCaptureError, error == .scrollingTooFast {
                captureGuidance = .scrollDownSlowly
                message = error.errorDescription
                notifyProgressChanged()
            } else if let error = error as? ScrollingCaptureError, error == .maximumHeightReached {
                captureService.stopCapture()
                phase = .processing
                processor.finish { [weak self] snapshot in
                    guard let self else {
                        return
                    }
                    guard let snapshot else {
                        self.phase = .idle
                        self.message = error.errorDescription
                        return
                    }
                    self.completedSnapshot = snapshot
                    self.message = error.errorDescription
                    self.onMaximumHeightReached?(snapshot)
                }
            } else {
                message = error.localizedDescription
            }
        }
    }

    private func resetCaptureFeedback() {
        lastAcceptedFrameFingerprint = nil
        lastIgnoredFrameFingerprint = nil
        consecutiveChangedIgnoredFrames = 0
    }

    private func resumeCaptureAfterProcessingIfNeeded() {
        guard phase == .capturing,
              queuedScrollActivity,
              !isManualCapturePending,
              !isManualCaptureInFlight,
              outstandingFrameCount < 2 else {
            return
        }
        queuedScrollActivity = false
        scheduleManualCapture()
    }

    private func recordAcceptedFrame(_ fingerprint: UInt64) {
        lastAcceptedFrameFingerprint = fingerprint
        lastIgnoredFrameFingerprint = nil
        consecutiveChangedIgnoredFrames = 0
    }

    private func recordIgnoredFrame(_ fingerprint: UInt64) {
        guard fingerprint != lastAcceptedFrameFingerprint else {
            lastIgnoredFrameFingerprint = nil
            consecutiveChangedIgnoredFrames = 0
            return
        }
        guard fingerprint != lastIgnoredFrameFingerprint else {
            return
        }

        lastIgnoredFrameFingerprint = fingerprint
        consecutiveChangedIgnoredFrames += 1
        if consecutiveChangedIgnoredFrames >= 3 {
            captureGuidance = .scrollDownSlowly
            notifyProgressChanged()
        }
    }

    private func notifyProgressChanged() {
        onProgressChanged?(captureGuidance, capturedFrameCount, capturedHeight)
    }

    private func publishPreview(_ preview: CGImage?) {
        guard let preview else {
            return
        }
        onPreviewChanged?(preview)
    }

    private var maximumCaptureHeight: Int {
        maximumHeightOverride ?? ScrollingCaptureHeightLimit.maximumHeight
    }
}
