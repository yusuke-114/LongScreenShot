//
//  ClothesLine.swift
//  LongScreenshot
//
//  The clothesline is adapted from Tendedero by Alejandro Buján, used under
//  the MIT License. See Tendedero-LICENSE.txt in this folder.
//

import AppKit
import Combine
import ImageIO
import os

nonisolated let clothesLineLog = Logger(subsystem: "LongScreenshot", category: "clothesline")

/// One finished capture hanging on the line.
struct ClothesLineItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// The security-scoped save folder the file lives in. The sandbox only
    /// lets us touch the file while access to this folder is open.
    let scope: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    static func == (a: ClothesLineItem, b: ClothesLineItem) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }

    /// Runs `body` with sandbox access to the item's folder open.
    func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        let didAccess = scope.startAccessingSecurityScopedResource()
        defer { if didAccess { scope.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move on their own. The line is only a view onto them.
@MainActor
final class ClothesLine: ObservableObject {
    @Published private(set) var items: [ClothesLineItem] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8

    var soundOn = true

    var liveCount: Int { items.filter { !$0.falling }.count }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((ClothesLineItem) -> Void)?

    init() {
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, scope: URL, thumb: NSImage, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }) else { return nil }
        var item = ClothesLineItem(url: url, scope: scope, thumb: thumb)
        item.flying = flying
        items.append(item)
        // A full line lets the oldest photo fall off the far end.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            drop(oldest.id, quietly: true)
        }
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling {
            let exists = item.withAccess { FileManager.default.fileExists(atPath: item.url.path) }
            if !exists { drop(item.id, quietly: true) }
        }
    }

    // MARK: Actions on one photo

    private func item(_ id: UUID) -> ClothesLineItem? {
        items.first { $0.id == id }
    }

    func copy(_ id: UUID) {
        guard let item = item(id) else { return }
        let entry = NSPasteboardItem()
        if let png = item.withAccess({ pngData(item.url) }) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = item(id) else { return }
        item.withAccess { _ = NSWorkspace.shared.open(item.url) }
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard let item = item(id) else { return }
        do {
            try item.withAccess { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
            if soundOn { Self.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            clothesLineLog.error("Could not trash \(item.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// The corner cross and "Take Down" end up here. The file stays where it
    /// was saved; only the photo leaves the line.
    func discard(_ id: UUID) {
        drop(id)
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = item(id) else { return }
        ClothesLineMarkup.shared.edit(item.url, scope: item.scope)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }) else { return }
        let item = items[i]
        guard let thumb = item.withAccess({ makeClothesLineThumbnail(url) }) else { return }
        items[i].thumb = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
    }

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        item.withAccess { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// The tallest a card may be relative to its width. Long screenshots are many
/// times taller than wide, so the card shows the top of the capture instead
/// of squeezing the whole page into a sliver.
nonisolated let clothesLineMaxAspect: CGFloat = 1.5

/// A thumbnail of the top of the image, never taller than
/// `clothesLineMaxAspect` times its width. Decoding is downsampled so even a
/// very long capture never lands in memory at full size. Safe off the main
/// thread; the caller must already have sandbox access to the file.
nonisolated func makeClothesLineThumbnail(_ url: URL, width targetWidth: Int = 520) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          pixelWidth > 0, pixelHeight > 0 else { return nil }

    // The thumbnail size is set by the longest side, so a tall image needs a
    // proportionally larger limit to come out `targetWidth` wide. A pixel
    // budget keeps the transient decode small for extreme captures.
    let budget = 8_000_000.0
    var width = min(pixelWidth, Double(targetWidth))
    if width * width * (pixelHeight / pixelWidth) > budget {
        width = (budget * pixelWidth / pixelHeight).squareRoot()
    }
    let longest = max(width, width * pixelHeight / pixelWidth)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longest.rounded())),
    ]
    guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

    let maxHeight = Int((CGFloat(full.width) * clothesLineMaxAspect).rounded())
    guard full.height > maxHeight else { return full }
    // CGImage cropping counts from the top row, which is the start of the page.
    // The crop still references the whole decoded page, so it is copied into
    // its own bitmap and the rest is released.
    guard let top = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: maxHeight)),
          let context = CGContext(
            data: nil, width: top.width, height: top.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: top.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(top, in: CGRect(x: 0, y: 0, width: top.width, height: top.height))
    return context.makeImage()
}
