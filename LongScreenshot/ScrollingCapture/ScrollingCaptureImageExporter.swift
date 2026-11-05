//
//  ScrollingCaptureImageExporter.swift
//  LongScreenshot
//

import AppKit
import CoreGraphics
import Foundation

struct ScrollingCaptureImageExporter {
    private let directoryProvider: () throws -> URL
    private let replacementDirectoryProvider: (URL) throws -> URL
    private let requiresSecurityScopedAccess: Bool
    private let now: () -> Date

    init(
        directoryProvider: @escaping () -> URL = {
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        },
        replacementDirectoryProvider: @escaping (URL) throws -> URL = { destination in
            try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destination,
                create: true
            )
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.directoryProvider = directoryProvider
        self.replacementDirectoryProvider = replacementDirectoryProvider
        requiresSecurityScopedAccess = false
        self.now = now
    }

    init(
        saveFolderPreferences: ScrollingCaptureSaveFolderPreferences,
        now: @escaping () -> Date = Date.init
    ) {
        directoryProvider = {
            guard let folder = try saveFolderPreferences.authorizedFolder() else {
                throw ScrollingCaptureSaveFolderError.authorizationRequired
            }
            return folder
        }
        replacementDirectoryProvider = { destination in
            try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destination,
                create: true
            )
        }
        requiresSecurityScopedAccess = true
        self.now = now
    }

    func save(image: CGImage) throws -> URL {
        guard let data = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]) else {
            throw ScrollingCaptureError.captureFailed(String(localized: "The scrolling screenshot could not be encoded as PNG."))
        }

        let directory = try directoryProvider()
        let didAccessDirectory = requiresSecurityScopedAccess && directory.startAccessingSecurityScopedResource()
        if requiresSecurityScopedAccess && !didAccessDirectory {
            throw ScrollingCaptureSaveFolderError.authorizationRequired
        }
        defer {
            if didAccessDirectory {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename(for: now()))
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func save(artifact: ScrollingCaptureArtifact) throws -> URL {
        defer { artifact.removeTemporaryFiles() }
        let directory = try directoryProvider()
        let didAccessDirectory = requiresSecurityScopedAccess && directory.startAccessingSecurityScopedResource()
        if requiresSecurityScopedAccess && !didAccessDirectory {
            throw ScrollingCaptureSaveFolderError.authorizationRequired
        }
        defer {
            if didAccessDirectory {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename(for: now()))
        let replacementDirectory = try replacementDirectoryProvider(directory)
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let stagedDestination = replacementDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try StreamingPNGEncoder().write(artifact: artifact, to: stagedDestination)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: stagedDestination, to: destination)
        return destination
    }

    private func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Scrolling Capture \(formatter.string(from: date)).png"
    }
}
