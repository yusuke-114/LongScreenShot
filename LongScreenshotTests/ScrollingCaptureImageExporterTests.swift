import CoreGraphics
import Foundation
import Testing
@testable import LongScreenshot

@Suite(.serialized)
struct ScrollingCaptureImageExporterTests {
    @Test func artifactExportUsesTheStreamingPNGEncoderInAReplacementDirectory() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repository.appendingPathComponent("LongScreenshot/ScrollingCapture/ScrollingCaptureImageExporter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("replacementDirectoryProvider(directory)"))
        #expect(source.contains("StreamingPNGEncoder().write(artifact: artifact, to: stagedDestination)"))
        #expect(!source.contains("artifact.makeImage()"))
    }

    @Test func saveFolderPreferencesRestoreTheUserAuthorizedFolder() throws {
        let suiteName = "ScrollingCaptureSaveFolderPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selectedFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Selected scrolling captures", isDirectory: true)
        let preferences = ScrollingCaptureSaveFolderPreferences(userDefaults: defaults, makeBookmark: { Data($0.path.utf8) }, resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
        try preferences.save(folder: selectedFolder)
        let restoredFolder = try #require(try preferences.authorizedFolder())
        #expect(restoredFolder.pathComponents == selectedFolder.pathComponents)
    }

    @Test func saveFolderPreferencesHaveNoAuthorizedFolderInitially() throws {
        let suiteName = "ScrollingCaptureSaveFolderPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ScrollingCaptureSaveFolderPreferences(userDefaults: defaults, makeBookmark: { Data($0.path.utf8) }, resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) })
        #expect(try preferences.authorizedFolder() == nil)
    }

    @Test func writesAPNGToTheConfiguredDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScrollingCaptureImageExporterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = ScrollingCaptureImageExporter(directoryProvider: { directory }, now: { Date(timeIntervalSince1970: 0) })
        let savedURL = try exporter.save(image: try makeTestImage())
        #expect(savedURL.deletingLastPathComponent().pathComponents == directory.pathComponents)
        #expect(savedURL.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
    }

    @Test func artifactExportKeepsStagingFilesOutOfTheChosenDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ScrollingCaptureImageExporterTests-\(UUID().uuidString)")
        let destinationDirectory = root.appendingPathComponent("exports")
        let stagingDirectory = root.appendingPathComponent("staging")
        let tileDirectory = root.appendingPathComponent("tiles")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScrollingCaptureTileStore(maximumHeight: 10, temporaryDirectoryProvider: { try FileManager.default.createDirectory(at: tileDirectory, withIntermediateDirectories: true); return tileDirectory })
        try store.appendInitial(makeTestImage())
        let artifact = try #require(store.makeArtifact())
        let exporter = ScrollingCaptureImageExporter(directoryProvider: { destinationDirectory }, replacementDirectoryProvider: { _ in try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true); return stagingDirectory }, now: { Date(timeIntervalSince1970: 0) })
        let savedURL = try exporter.save(artifact: artifact)
        let exportedNames = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
        #expect(exportedNames == [savedURL.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    private func makeTestImage() throws -> CGImage {
        let bytes = Data([255, 0, 0, 255])
        return try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
