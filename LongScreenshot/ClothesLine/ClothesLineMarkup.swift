//
//  ClothesLineMarkup.swift
//  LongScreenshot
//
//  Adapted from Tendedero by Alejandro Buján, MIT License.
//

import AppKit
import os
import UniformTypeIdentifiers

/// Opens a capture in the system Markup editor, the window macOS shows when
/// you click the thumbnail of a screenshot you just took. It is a system
/// extension, reached through the public sharing service it registers.
@MainActor
final class ClothesLineMarkup: NSObject, NSSharingServiceDelegate {
    static let shared = ClothesLineMarkup()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }

    private var editing: (url: URL, scope: URL)?
    /// The save folder whose sandbox access stays open while Markup is up,
    /// since the extension reads the file after `perform` returns.
    private var openScope: URL?
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    func edit(_ url: URL, scope: URL) {
        closeScope()
        let didAccess = scope.startAccessingSecurityScopedResource()
        guard let service = NSSharingService(named: Self.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            if didAccess { scope.stopAccessingSecurityScopedResource() }
            return
        }
        if didAccess { openScope = scope }
        editing = (url, scope)
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: NSSharingServiceDelegate

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { self.save(items) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        clothesLineLog.notice("Markup ended without saving: \(error.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated {
            self.editing = nil
            self.closeScope()
        }
    }

    private func closeScope() {
        openScope?.stopAccessingSecurityScopedResource()
        openScope = nil
    }

    // MARK: Writing back

    private func save(_ items: [Any]) {
        // Writing back opens access again on its own, including the
        // asynchronous item provider path.
        defer { closeScope() }
        guard let target = editing, let item = items.first else { return }
        editing = nil

        switch item {
        case let url as URL:
            write(from: url, to: target)
        case let image as NSImage:
            write(data: pngData(image), to: target)
        case let provider as NSItemProvider:
            load(provider, into: target)
        default:
            clothesLineLog.error("Markup returned an unexpected item")
        }
    }

    private func load(_ provider: NSItemProvider, into target: (url: URL, scope: URL)) {
        let types = provider.registeredTypeIdentifiers
        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { if let url { self.write(from: url, to: target) } }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.url.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else { return }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async { self.write(data: data, to: target) }
        }
    }

    private func write(from source: URL, to target: (url: URL, scope: URL)) {
        if source.standardizedFileURL == target.url.standardizedFileURL {
            onSaved(target.url)
        } else {
            write(data: try? Data(contentsOf: source), to: target)
        }
    }

    private func write(data: Data?, to target: (url: URL, scope: URL)) {
        guard let data else { return }
        let didAccess = target.scope.startAccessingSecurityScopedResource()
        defer { if didAccess { target.scope.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: target.url, options: .atomic)
            onSaved(target.url)
        } catch {
            clothesLineLog.error("Could not save markup: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
