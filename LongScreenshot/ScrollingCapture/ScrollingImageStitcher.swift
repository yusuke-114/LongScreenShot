import CoreGraphics

struct ScrollingImageStitcher {
    private let maximumHeight: Int
    private let offsetEstimator: any VerticalOffsetEstimating
    private var tileStore: ScrollingCaptureTileStore?
    private var lastAcceptedImage: CGImage?

    init(maximumHeight: Int = ScrollingCaptureHeightLimit.maximumHeight, offsetEstimator: any VerticalOffsetEstimating = VisionVerticalOffsetEstimator()) {
        self.maximumHeight = maximumHeight
        self.offsetEstimator = offsetEstimator
    }

    var artifact: ScrollingCaptureArtifact? { tileStore?.makeArtifact() }
    func previewImage(maximumSize: CGSize) -> CGImage? { tileStore?.previewImage(maximumSize: maximumSize) }

    mutating func takeArtifact() -> ScrollingCaptureArtifact? {
        let artifact = tileStore?.makeArtifact()
        tileStore = nil
        lastAcceptedImage = nil
        return artifact
    }

    mutating func append(_ frame: ScrollingCaptureFrame) throws -> ScrollingImageAppendResult {
        if tileStore == nil {
            let store = try ScrollingCaptureTileStore(maximumHeight: maximumHeight)
            try store.appendInitial(frame.image)
            tileStore = store
            lastAcceptedImage = frame.image
            return .started
        }

        guard let store = tileStore,
              let previous = lastAcceptedImage,
              let addedHeight = offsetEstimator.estimateDownwardOffset(from: frame.image, to: previous),
              addedHeight > 0,
              addedHeight < frame.image.height,
              addedHeight >= max(1, frame.image.height / 10) else {
            return .ignored
        }

        try store.appendBottomRows(from: frame.image, count: addedHeight)
        lastAcceptedImage = frame.image
        return .appended(addedHeight: addedHeight)
    }

    mutating func discard() {
        tileStore?.discard()
        tileStore = nil
        lastAcceptedImage = nil
    }
}
