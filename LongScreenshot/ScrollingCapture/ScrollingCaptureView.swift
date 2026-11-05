//
//  ScrollingCaptureView.swift
//  LongScreenshot
//

import AppKit
import Carbon
import SwiftUI

struct ScrollingCaptureView: View {
    @Environment(ScrollingCaptureCoordinator.self) private var coordinator
    @State private var isRecordingShortcut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroSection

                GlassEffectContainer(spacing: 16) {
                    setupCards
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Capture setup")
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
        }
    }

    /// The window uses a hidden title bar, so this heading is the only title the
    /// user actually sees - which is where a debug build has to announce itself.
    static var title: String {
        #if DEBUG
        String(localized: "Long Screenshot (Debug Mode)")
        #else
        String(localized: "Long Screenshot")
        #endif
    }

    private var heroSection: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: LongScreenshotAppIcon.image)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityLabel("Long Screenshot app icon")
                .accessibilityIdentifier("LongScreenshotAppIcon")

            VStack(alignment: .leading, spacing: 7) {
                Text(Self.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Capture beyond the viewport")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("Set a global shortcut, select a scrollable area in any app, then scroll downward to create one seamless image.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear, in: .rect(cornerRadius: 26))
    }

    private var setupCards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                shortcutSection
                    .frame(minWidth: 420)
                saveFolderSection
                    .frame(minWidth: 420)
            }

            VStack(alignment: .leading, spacing: 16) {
                shortcutSection
                saveFolderSection
            }
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keyboard Shortcut", systemImage: "keyboard")
                .font(.headline)

            HStack(spacing: 12) {
                Text(shortcutDisplayName(coordinator.shortcutManager.shortcut))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(
                        coordinator.shortcutManager.shortcut == nil ? .secondary : .primary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button(
                        isRecordingShortcut
                            ? String(localized: "Press shortcut…")
                            : String(localized: "Record Shortcut")
                    ) {
                        isRecordingShortcut = true
                    }
                    .buttonStyle(.glassProminent)

                    Button("Clear Shortcut") {
                        coordinator.shortcutManager.clear()
                        isRecordingShortcut = false
                    }
                    .disabled(coordinator.shortcutManager.shortcut == nil)
                }
            }

            if isRecordingShortcut {
                Text("Press the shortcut you want to use. Press Escape to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ShortcutRecorderView(isRecording: $isRecordingShortcut) { shortcut in
                do {
                    try coordinator.shortcutManager.save(shortcut)
                } catch {
                    // The shortcut manager supplies a user-facing reason.
                }
                isRecordingShortcut = false
            }
            .frame(width: 1, height: 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear, in: .rect(cornerRadius: 22))
    }

    private var saveFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Save Folder", systemImage: "folder")
                .font(.headline)

            HStack(spacing: 12) {
                Text(coordinator.saveFolderDisplayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose Save Folder…") {
                    coordinator.chooseSaveFolder()
                }
                .buttonStyle(.glass)
            }

            Text("Choose a folder once to allow automatic exports there.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            @Bindable var coordinator = coordinator
            Toggle("Show Screenshots on Clothesline", isOn: $coordinator.hangsOnClothesLine)
            .toggleStyle(.switch)
            .accessibilityIdentifier("ClothesLineToggle")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear, in: .rect(cornerRadius: 22))
    }

    private func shortcutDisplayName(_ shortcut: ScrollingCaptureShortcut?) -> String {
        guard let shortcut else {
            return String(localized: "Not set")
        }

        var result = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName(for: shortcut.keyCode)
    }

    private func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M", 49: String(localized: "Space"), 53: "Esc"
        ]
        return names[keyCode] ?? String(localized: "Key \(Int(keyCode))")
    }
}

private struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onShortcut: (ScrollingCaptureShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcut = onShortcut
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        view.onShortcut = onShortcut
        view.onCancel = { isRecording = false }
        view.isRecording = isRecording
        guard isRecording else {
            return
        }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}

private final class ShortcutRecorderNSView: NSView {
    var isRecording = false
    var onShortcut: ((ScrollingCaptureShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        guard event.keyCode != 53 else {
            onCancel?()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        onShortcut?(ScrollingCaptureShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }
}
