//
//  StatusBarManager.swift
//  LongScreenshot
//

import AppKit

@MainActor
final class StatusBarManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var clothesLineItems: [NSMenuItem] = []
    private var takeDownItem: NSMenuItem?
    #if DEBUG
    private var recordingItem: NSMenuItem?
    #endif
    var onOpenMainWindow: (() -> Void)?

    func setupStatusBar(onOpen: @escaping () -> Void) {
        self.onOpenMainWindow = onOpen
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            if let image = NSImage(systemSymbolName: "arrow.up.and.down.square", accessibilityDescription: String(localized: "Long Screenshot"))?.withSymbolConfiguration(symbolConfig) {
                image.isTemplate = true
                button.image = image
            }
            button.toolTip = String(localized: "Long Screenshot")
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: String(localized: "Open Long Screenshot"),
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let clothesLineSeparator = NSMenuItem.separator()
        menu.addItem(clothesLineSeparator)
        let showClothesLineItem = NSMenuItem(
            title: String(localized: "Show Clothesline"),
            action: #selector(showClothesLine),
            keyEquivalent: ""
        )
        showClothesLineItem.target = self
        menu.addItem(showClothesLineItem)
        let takeDownItem = NSMenuItem(
            title: String(localized: "Take Everything Down"),
            action: #selector(takeEverythingDown),
            keyEquivalent: ""
        )
        takeDownItem.target = self
        menu.addItem(takeDownItem)
        self.takeDownItem = takeDownItem
        clothesLineItems = [clothesLineSeparator, showClothesLineItem, takeDownItem]

        #if DEBUG
        menu.addItem(NSMenuItem.separator())
        let recordingItem = NSMenuItem(
            title: String(localized: "Recording Mode"),
            action: #selector(toggleRecordingMode),
            keyEquivalent: ""
        )
        recordingItem.target = self
        recordingItem.state = OverlayRecordingMode.isEnabled ? .on : .off
        recordingItem.toolTip = String(localized: "Let screen recorders see the capture overlay. Debug builds only.")
        menu.addItem(recordingItem)
        self.recordingItem = recordingItem
        #endif

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The clothesline items only appear while the feature is turned on.
        let enabled = ClothesLinePreferences().isEnabled
        clothesLineItems.forEach { $0.isHidden = !enabled }
        guard enabled else { return }
        takeDownItem?.isEnabled = ClothesLineController.shared.hasItems
    }

    @objc private func showClothesLine() {
        ClothesLineController.shared.show()
    }

    @objc private func takeEverythingDown() {
        ClothesLineController.shared.takeEverythingDown()
    }

    @objc func openMainWindow() {
        onOpenMainWindow?()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    #if DEBUG
    @objc private func toggleRecordingMode() {
        OverlayRecordingMode.setEnabled(!OverlayRecordingMode.isEnabled)
        recordingItem?.state = OverlayRecordingMode.isEnabled ? .on : .off
    }
    #endif
}
