//
//  ScreenRegionCaptureService.swift
//  LongScreenshot
//

@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

@MainActor
final class ScreenRegionCaptureService: NSObject, ScreenRegionCapturing, SCStreamOutput {
    private var contentFilter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var stream: SCStream?
    /// The newest surface handed over by the stream. Holding the buffer instead
    /// of a rendered image keeps the 30 fps stream from paying for a full-frame
    /// rasterization that nobody asked for.
    private var latestSurface: CapturedSurface?
    private var initialFrameHandler: ((ScrollingCaptureFrame) -> Void)?
    private var isDeliveringInitialFrame = false
    private let streamOutputQueue = DispatchQueue(
        label: "com.longscreenshot.scrolling-capture.stream-output",
        qos: .userInitiated
    )
    private nonisolated static let conversionQueue = DispatchQueue(
        label: "com.longscreenshot.scrolling-capture.frame-conversion",
        qos: .userInitiated
    )
    private nonisolated static let imageContext = CIContext()

    func requestPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func startCapture(
        selection: ScrollingCaptureSelection,
        onFrame: @escaping (ScrollingCaptureFrame) -> Void
    ) async throws {
        stopCapture()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw ScrollingCaptureError.captureFailed(String(localized: "The selected display is no longer available."))
        }

        let sourceRect = selection.sourceRect.integral
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            throw ScrollingCaptureError.captureFailed(String(localized: "Select a visible area to capture."))
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(selection.pixelSize.width)
        configuration.height = Int(selection.pixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: streamOutputQueue
        )

        contentFilter = filter
        self.configuration = configuration
        latestSurface = nil
        isDeliveringInitialFrame = false
        initialFrameHandler = onFrame
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            initialFrameHandler = nil
            throw error
        }
    }

    func captureFrame() async throws -> ScrollingCaptureFrame? {
        guard let latestSurface else {
            return nil
        }
        return await Self.makeFrame(from: latestSurface)
    }

    func stopCapture() {
        let activeStream = stream
        stream = nil
        contentFilter = nil
        configuration = nil
        latestSurface = nil
        initialFrameHandler = nil
        isDeliveringInitialFrame = false
        if let activeStream {
            Task {
                try? await activeStream.stopCapture()
            }
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let surface = CapturedSurface(pixelBuffer: pixelBuffer)
        Task { @MainActor [weak self] in
            self?.receiveStreamSurface(surface, from: stream)
        }
    }

    private func receiveStreamSurface(_ surface: CapturedSurface, from stream: SCStream) {
        guard self.stream === stream else {
            return
        }
        latestSurface = surface

        guard initialFrameHandler != nil, !isDeliveringInitialFrame else {
            return
        }
        isDeliveringInitialFrame = true
        Task { @MainActor [weak self] in
            let frame = await Self.makeFrame(from: surface)
            guard let self else {
                return
            }
            self.isDeliveringInitialFrame = false
            guard let frame,
                  self.stream === stream,
                  let handler = self.initialFrameHandler else {
                return
            }
            self.initialFrameHandler = nil
            handler(frame)
        }
    }

    /// Rasterizes a captured surface off the main actor so scrolling stays smooth.
    private nonisolated static func makeFrame(
        from surface: CapturedSurface
    ) async -> ScrollingCaptureFrame? {
        await withCheckedContinuation { continuation in
            conversionQueue.async {
                let image = CIImage(cvPixelBuffer: surface.pixelBuffer)
                guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ScrollingCaptureFrame(image: cgImage))
            }
        }
    }
}


/// A frame surface handed over by `SCStream`. The buffer is only ever read, and
/// the pool keeps its contents alive for as long as this reference exists, so it
/// is safe to move between the stream queue and the main actor.
private struct CapturedSurface: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}
