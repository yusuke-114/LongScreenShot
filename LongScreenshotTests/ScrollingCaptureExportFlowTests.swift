import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LongScreenshot

/// Drives a whole capture through the coordinator, store, processor, stitcher
/// and exporter so the end-to-end screenshot path stays covered.
@Suite(.serialized)
struct ScrollingCaptureExportFlowTests {
    private static let width = 96
    private static let viewportHeight = 120

    @Test @MainActor func aFinishedCaptureIsStitchedAndExportedAsAPNG() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let saveFolder = scratch.appendingPathComponent("exports")

        let page = SyntheticPage(width: Self.width, height: 600)
        let offsets = [40, 55]
        let context = try makeContext(
            page: page,
            offsets: offsets,
            saveFolder: saveFolder,
            chosenFolder: saveFolder,
            defaultsSuite: scratch.lastPathComponent
        )
        defer { context.tearDown() }

        try await context.store.beginCapture(selection: makeSelection())
        try await waitUntil { context.store.capturedFrameCount == 1 }

        for expectedFrameCount in 2...(offsets.count + 1) {
            context.store.captureAfterScrollActivity()
            try await waitUntil { context.store.capturedFrameCount == expectedFrameCount }
        }

        context.coordinator.finishCapture()
        try await waitUntil { context.store.phase == .finished }

        #expect(context.coordinator.completedCaptureCount == 1)

        let exported = try FileManager.default.contentsOfDirectory(atPath: saveFolder.path)
        #expect(exported.count == 1)
        let savedURL = saveFolder.appendingPathComponent(try #require(exported.first))
        #expect(savedURL.pathExtension == "png")

        let expectedHeight = Self.viewportHeight + offsets.reduce(0, +)
        let decoded = try decode(at: savedURL)
        #expect(decoded.width == Self.width)
        #expect(decoded.height == expectedHeight)
        #expect(decoded.rowIdentifiers == page.rowIdentifiers(from: 0, count: expectedHeight))
    }

    @Test @MainActor func decliningTheSaveFolderReportsTheFailureAndReleasesTheTiles() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let saveFolder = scratch.appendingPathComponent("exports")

        let page = SyntheticPage(width: Self.width, height: 600)
        let context = try makeContext(
            page: page,
            offsets: [40],
            saveFolder: saveFolder,
            chosenFolder: nil,
            defaultsSuite: scratch.lastPathComponent
        )
        defer { context.tearDown() }

        try await context.store.beginCapture(selection: makeSelection())
        try await waitUntil { context.store.capturedFrameCount == 1 }
        context.store.captureAfterScrollActivity()
        try await waitUntil { context.store.capturedFrameCount == 2 }

        context.coordinator.finishCapture()
        try await waitUntil { context.store.phase == .finished }

        #expect(context.coordinator.completedCaptureCount == 0)
        #expect(
            context.store.message
                == String(localized: "Scrolling screenshot was not saved because no save folder was selected.")
        )
        #expect(!FileManager.default.fileExists(atPath: saveFolder.path))
        // The abandoned capture must not strand its tiles in the temporary
        // directory, because nothing holds a reference to them any more.
        #expect(remainingCaptureTileDirectories().isSubset(of: context.preexistingTileDirectories))
    }

    @Test @MainActor func withTheClotheslineOnASavedCaptureHangsFromItsSaveFolder() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let saveFolder = scratch.appendingPathComponent("exports")

        let context = try makeContext(
            page: SyntheticPage(width: Self.width, height: 600),
            offsets: [40],
            saveFolder: saveFolder,
            chosenFolder: saveFolder,
            defaultsSuite: scratch.lastPathComponent,
            hangsOnClothesLine: true
        )
        defer { context.tearDown() }

        try await runCapture(context, scrolls: 1)

        let exported = try FileManager.default.contentsOfDirectory(atPath: saveFolder.path)
        let savedURL = saveFolder.appendingPathComponent(try #require(exported.first))
        #expect(context.clothesLine.hung.map(\.url.lastPathComponent) == [savedURL.lastPathComponent])
        #expect(context.clothesLine.hung.first?.scope.standardizedFileURL == saveFolder.standardizedFileURL)
    }

    @Test @MainActor func withTheClotheslineOffNothingHangs() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let saveFolder = scratch.appendingPathComponent("exports")

        let context = try makeContext(
            page: SyntheticPage(width: Self.width, height: 600),
            offsets: [40],
            saveFolder: saveFolder,
            chosenFolder: saveFolder,
            defaultsSuite: scratch.lastPathComponent
        )
        defer { context.tearDown() }

        try await runCapture(context, scrolls: 1)

        #expect(context.coordinator.completedCaptureCount == 1)
        #expect(context.clothesLine.hung.isEmpty)
    }

    @Test @MainActor func turningTheClotheslineOffIsRememberedAndTakesEverythingDown() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let context = try makeContext(
            page: SyntheticPage(width: Self.width, height: 600),
            offsets: [],
            saveFolder: scratch,
            chosenFolder: scratch,
            defaultsSuite: scratch.lastPathComponent,
            hangsOnClothesLine: true
        )
        defer { context.tearDown() }

        #expect(context.coordinator.hangsOnClothesLine)
        context.coordinator.hangsOnClothesLine = false

        #expect(context.clothesLine.takeDownCount == 1)
        #expect(!context.clothesLinePreferences.isEnabled)
    }

    @MainActor
    private func runCapture(_ context: Context, scrolls: Int) async throws {
        try await context.store.beginCapture(selection: makeSelection())
        try await waitUntil { context.store.capturedFrameCount == 1 }
        for expectedFrameCount in stride(from: 2, through: scrolls + 1, by: 1) {
            context.store.captureAfterScrollActivity()
            try await waitUntil { context.store.capturedFrameCount == expectedFrameCount }
        }
        context.coordinator.finishCapture()
        try await waitUntil { context.store.phase == .finished }
    }

    // MARK: - Fixture

    private struct Context {
        let coordinator: ScrollingCaptureCoordinator
        let store: ScrollingCaptureStore
        let clothesLine: StubClothesLine
        let clothesLinePreferences: ClothesLinePreferences
        let preexistingTileDirectories: Set<String>
        let tearDown: () -> Void
    }

    @MainActor
    private func makeContext(
        page: SyntheticPage,
        offsets: [Int],
        saveFolder: URL,
        chosenFolder: URL?,
        defaultsSuite: String,
        hangsOnClothesLine: Bool = false
    ) throws -> Context {
        let preexisting = remainingCaptureTileDirectories()

        var frames = [page.frame(top: 0, height: Self.viewportHeight)]
        var top = 0
        for offset in offsets {
            top += offset
            frames.append(page.frame(top: top, height: Self.viewportHeight))
        }

        let store = ScrollingCaptureStore(
            captureService: StubScreenRegionCaptureService(frames: frames),
            offsetEstimator: ScriptedOffsetEstimator(offsets: offsets)
        )
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        let preferences = ScrollingCaptureSaveFolderPreferences(
            userDefaults: defaults,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) }
        )
        let clothesLinePreferences = ClothesLinePreferences(userDefaults: defaults)
        clothesLinePreferences.isEnabled = hangsOnClothesLine
        let clothesLine = StubClothesLine()
        let coordinator = ScrollingCaptureCoordinator(
            store: store,
            overlayController: StubOverlayController(),
            saveFolderPreferences: preferences,
            imageExporter: ScrollingCaptureImageExporter(
                directoryProvider: { saveFolder },
                now: { Date(timeIntervalSince1970: 0) }
            ),
            saveFolderChooser: { _ in chosenFolder },
            clothesLinePreferences: clothesLinePreferences,
            clothesLine: { clothesLine }
        )

        return Context(
            coordinator: coordinator,
            store: store,
            clothesLine: clothesLine,
            clothesLinePreferences: clothesLinePreferences,
            preexistingTileDirectories: preexisting,
            tearDown: { defaults.removePersistentDomain(forName: defaultsSuite) }
        )
    }

    private func makeSelection() -> ScrollingCaptureSelection {
        ScrollingCaptureSelection(
            displayID: 1,
            sourceRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight),
            backingScale: 1
        )
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScrollingCaptureExportFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func remainingCaptureTileDirectories() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return Set(contents.filter { $0.hasPrefix("LongScreenshot-ScrollingCapture-") })
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the capture pipeline to make progress.")
    }

    private struct DecodedCapture {
        let width: Int
        let height: Int
        let rowIdentifiers: [UInt8]
    }

    private func decode(at url: URL) throws -> DecodedCapture {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var identifiers: [UInt8] = []
        for row in 0..<height {
            identifiers.append(bytes[row * width * 4])
        }
        return DecodedCapture(width: width, height: height, rowIdentifiers: identifiers)
    }
}

@MainActor
private final class StubScreenRegionCaptureService: ScreenRegionCapturing {
    private let frames: [ScrollingCaptureFrame]
    private var nextIndex = 0

    init(frames: [ScrollingCaptureFrame]) {
        self.frames = frames
    }

    func requestPermission() -> Bool { true }

    func startCapture(
        selection: ScrollingCaptureSelection,
        onFrame: @escaping (ScrollingCaptureFrame) -> Void
    ) async throws {
        nextIndex = 1
        onFrame(frames[0])
    }

    func captureFrame() async throws -> ScrollingCaptureFrame? {
        guard nextIndex < frames.count else { return nil }
        defer { nextIndex += 1 }
        return frames[nextIndex]
    }

    func stopCapture() {}
}

@MainActor
private final class StubOverlayController: ScrollingCaptureOverlayControlling {
    func presentSelection(completion: @escaping (ScrollingCaptureSelection?) -> Void) {}
    func presentCaptureControls(onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {}
    func presentCaptureGuidance(
        for selection: ScrollingCaptureSelection,
        guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    ) {}
    func updateCaptureGuidance(
        _ guidance: ScrollingCaptureGuidance,
        frameCount: Int,
        capturedHeight: Int
    ) {}
    func updateCapturePreview(_ image: CGImage) {}
    func dismissAll() {}
}

@MainActor
private final class StubClothesLine: ClothesLineHanging {
    private(set) var hung: [(url: URL, scope: URL)] = []
    private(set) var takeDownCount = 0

    func hang(_ url: URL, scope: URL, from origin: CGRect?) {
        hung.append((url, scope))
    }

    func takeEverythingDown() {
        takeDownCount += 1
    }
}
