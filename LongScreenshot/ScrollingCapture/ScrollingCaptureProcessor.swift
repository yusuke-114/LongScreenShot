//
//  ScrollingCaptureProcessor.swift
//  LongScreenshot
//

import CoreGraphics
import Foundation

final class ScrollingCaptureProcessor: @unchecked Sendable {
    struct Update {
        let result: ScrollingImageAppendResult
        let fingerprint: UInt64
        let frameHeight: Int
        let preview: CGImage?
    }

    var onUpdate: ((Result<Update, Error>) -> Void)?

    private let processingQueue: DispatchQueue
    private let offsetEstimator: any VerticalOffsetEstimating
    private let stateLock = NSLock()
    private var stitcher: ScrollingImageStitcher
    private var pendingFrames: [ScrollingCaptureFrame] = []
    private let maximumPendingFrameCount: Int
    private var isProcessing = false
    private var acceptsFrames = false
    private var generation = 0
    private var finishCompletion: ((ScrollingCaptureArtifact?) -> Void)?

    init(
        maximumHeight: Int = ScrollingCaptureHeightLimit.maximumHeight,
        maximumPendingFrameCount: Int = 2,
        processingQueue: DispatchQueue? = nil,
        offsetEstimator: any VerticalOffsetEstimating
    ) {
        self.processingQueue = processingQueue ?? DispatchQueue(
            label: "com.longscreenshot.scrolling-capture.stitching",
            qos: .userInitiated
        )
        self.maximumPendingFrameCount = max(0, maximumPendingFrameCount)
        self.offsetEstimator = offsetEstimator
        stitcher = ScrollingImageStitcher(
            maximumHeight: maximumHeight,
            offsetEstimator: offsetEstimator
        )
    }

    func start(maximumHeight: Int) {
        stateLock.lock()
        generation += 1
        let activeGeneration = generation
        pendingFrames = []
        isProcessing = false
        acceptsFrames = true
        finishCompletion = nil
        stateLock.unlock()

        processingQueue.async { [weak self] in
            guard let self, self.isCurrent(activeGeneration) else {
                return
            }
            self.stitcher.discard()
            self.stitcher = ScrollingImageStitcher(
                maximumHeight: maximumHeight,
                offsetEstimator: self.offsetEstimator
            )
        }
    }

    func enqueue(_ frame: ScrollingCaptureFrame) {
        stateLock.lock()
        guard acceptsFrames else {
            stateLock.unlock()
            return
        }

        let activeGeneration = generation
        if isProcessing {
            guard pendingFrames.count < maximumPendingFrameCount else {
                stateLock.unlock()
                publish(.failure(ScrollingCaptureError.scrollingTooFast), generation: activeGeneration)
                return
            }
            pendingFrames.append(frame)
            stateLock.unlock()
            return
        }

        isProcessing = true
        stateLock.unlock()
        scheduleProcessing(frame, generation: activeGeneration)
    }

    func finish(completion: @escaping (ScrollingCaptureArtifact?) -> Void) {
        stateLock.lock()
        acceptsFrames = false
        let activeGeneration = generation
        finishCompletion = completion
        let shouldFinishImmediately = !isProcessing
        if shouldFinishImmediately {
            isProcessing = true
        }
        stateLock.unlock()

        if shouldFinishImmediately {
            scheduleFinish(generation: activeGeneration)
        }
    }

    func cancel() {
        stateLock.lock()
        generation += 1
        pendingFrames = []
        isProcessing = false
        acceptsFrames = false
        finishCompletion = nil
        stateLock.unlock()

        processingQueue.async { [weak self] in
            self?.stitcher.discard()
        }
    }

    private func scheduleProcessing(_ frame: ScrollingCaptureFrame, generation: Int) {
        processingQueue.async { [weak self] in
            self?.process(frame, generation: generation)
        }
    }

    private func process(_ frame: ScrollingCaptureFrame, generation: Int) {
        guard isCurrent(generation) else {
            return
        }

        let update: Result<Update, Error>
        var reachedMaximumHeight = false
        do {
            let result = try stitcher.append(frame)
            let preview: CGImage?
            switch result {
            case .started, .appended:
                preview = stitcher.previewImage(maximumSize: CGSize(width: 180, height: 320))
            case .ignored:
                preview = nil
            }
            update = .success(Update(
                result: result,
                fingerprint: frameFingerprint(frame.image),
                frameHeight: frame.image.height,
                preview: preview
            ))
        } catch {
            if let captureError = error as? ScrollingCaptureError,
               captureError == .maximumHeightReached {
                stateLock.lock()
                guard self.generation == generation else {
                    stateLock.unlock()
                    return
                }
                acceptsFrames = false
                pendingFrames = []
                stateLock.unlock()
                reachedMaximumHeight = true
            }
            update = .failure(error)
        }

        publish(update, generation: generation)

        stateLock.lock()
        guard self.generation == generation else {
            stateLock.unlock()
            return
        }
        if reachedMaximumHeight {
            let shouldFinish = finishCompletion != nil
            if !shouldFinish {
                isProcessing = false
            }
            stateLock.unlock()

            if shouldFinish {
                scheduleFinish(generation: generation)
            }
            return
        }
        let nextFrame = pendingFrames.isEmpty ? nil : pendingFrames.removeFirst()
        let shouldFinish = nextFrame == nil && finishCompletion != nil
        if nextFrame == nil, !shouldFinish {
            isProcessing = false
        }
        stateLock.unlock()

        if let nextFrame {
            scheduleProcessing(nextFrame, generation: generation)
        } else if shouldFinish {
            scheduleFinish(generation: generation)
        }
    }

    private func publish(_ update: Result<Update, Error>, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(generation) else {
                return
            }
            self.onUpdate?(update)
        }
    }

    private func scheduleFinish(generation: Int) {
        processingQueue.async { [weak self] in
            guard let self, self.isCurrent(generation) else {
                return
            }
            let snapshot = self.stitcher.takeArtifact()

            self.stateLock.lock()
            guard self.generation == generation else {
                self.stateLock.unlock()
                return
            }
            let completion = self.finishCompletion
            self.finishCompletion = nil
            self.isProcessing = false
            self.stateLock.unlock()

            DispatchQueue.main.async {
                completion?(snapshot)
            }
        }
    }

    private func isCurrent(_ candidate: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == candidate
    }

    private func frameFingerprint(_ image: CGImage) -> UInt64 {
        guard let data = image.dataProvider?.data else {
            return (UInt64(image.width) << 32) | UInt64(image.height)
        }

        let bytes = CFDataGetBytePtr(data)
        let byteCount = CFDataGetLength(data)
        guard let bytes, byteCount > 0 else {
            return (UInt64(image.width) << 32) | UInt64(image.height)
        }

        let sampleCount = min(128, byteCount)
        let step = max(1, byteCount / sampleCount)
        var fingerprint: UInt64 = 1_469_598_103_934_665_603
        for index in stride(from: 0, to: byteCount, by: step) {
            fingerprint ^= UInt64(bytes[index])
            fingerprint &*= 1_099_511_628_211
        }
        return fingerprint
    }
}
