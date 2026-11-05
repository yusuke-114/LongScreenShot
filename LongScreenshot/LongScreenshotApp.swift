//
//  LongScreenshotApp.swift
//  LongScreenshot
//

import AppKit
import SwiftUI

@MainActor
enum LongScreenshotAppIcon {
    static var image: NSImage {
        guard
            let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        else {
            return NSApplication.shared.applicationIconImage
        }
        return image
    }
}

@MainActor
final class MainWindowLifecycleController: NSObject, NSWindowDelegate {
    static let shared = MainWindowLifecycleController()
    private(set) weak var primaryWindow: NSWindow?

    func setupInterception() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let isStatusBarWindow = window.className.contains("NSStatusBar") || window.className.contains("Menu")
        if !isStatusBarWindow && window.level == .normal && window.canBecomeMain {
            if primaryWindow == nil {
                primaryWindow = window
                window.isReleasedWhenClosed = false
                window.delegate = self
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === primaryWindow {
            sender.orderOut(nil)
            return false
        }
        return true
    }
}

@MainActor
final class LongScreenshotAppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarManager: StatusBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LongScreenshotAppearance.apply()
        MainWindowLifecycleController.shared.setupInterception()
        let manager = StatusBarManager()
        manager.setupStatusBar { [weak self] in
            self?.showMainWindow()
        }
        self.statusBarManager = manager
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let targetWindow = MainWindowLifecycleController.shared.primaryWindow ?? NSApp.windows.first { window in
            let isStatusBarWindow = window.className.contains("NSStatusBar") || window.className.contains("Menu")
            return !isStatusBarWindow && window.canBecomeMain && window.level == .normal
        }

        if let targetWindow {
            if targetWindow.isMiniaturized {
                targetWindow.deminiaturize(nil)
            }
            targetWindow.setIsVisible(true)
            targetWindow.makeKeyAndOrderFront(nil)
            targetWindow.orderFrontRegardless()
        }
    }
}

@main
struct LongScreenshotApp: App {
    @NSApplicationDelegateAdaptor(LongScreenshotAppDelegate.self) private var appDelegate
    @State private var scrollingCaptureCoordinator = ScrollingCaptureCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scrollingCaptureCoordinator)
                .preferredColorScheme(.dark)
                // Also names the window in the Window menu and Mission Control,
                // where the hidden title bar cannot show it.
                .navigationTitle(ScrollingCaptureView.title)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
    }
}
