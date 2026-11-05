//
//  ScrollingCaptureShortcutManager.swift
//  LongScreenshot
//

import Carbon
import Foundation
import Observation

@MainActor
protocol GlobalHotKeyRegistration: AnyObject {
    func invalidate()
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        _ shortcut: ScrollingCaptureShortcut,
        onPress: @escaping () -> Void
    ) throws -> any GlobalHotKeyRegistration
}

@MainActor
@Observable
final class ScrollingCaptureShortcutManager {
    private let registrar: any GlobalHotKeyRegistering
    private let preferences: ScrollingCaptureShortcutPreferences
    private var activeRegistration: (any GlobalHotKeyRegistration)?

    private(set) var shortcut: ScrollingCaptureShortcut?
    private(set) var message: String?
    var onShortcutPressed: (() -> Void)?

    init(
        registrar: (any GlobalHotKeyRegistering)? = nil,
        preferences: ScrollingCaptureShortcutPreferences? = nil
    ) {
        self.registrar = registrar ?? CarbonGlobalHotKeyRegistrar.shared
        let resolvedPreferences = preferences ?? ScrollingCaptureShortcutPreferences()
        self.preferences = resolvedPreferences

        do {
            guard let savedShortcut = try resolvedPreferences.load() else {
                return
            }
            try savedShortcut.validate()
            activeRegistration = try self.registrar.register(savedShortcut) { [weak self] in
                self?.onShortcutPressed?()
            }
            shortcut = savedShortcut
        } catch {
            resolvedPreferences.clear()
            message = ScrollingCaptureShortcutError.conflict.errorDescription
        }
    }

    func save(_ candidate: ScrollingCaptureShortcut) throws {
        do {
            try candidate.validate()
        } catch {
            message = error.localizedDescription
            throw error
        }
        guard candidate != shortcut else {
            message = nil
            return
        }

        let registration: any GlobalHotKeyRegistration
        do {
            registration = try registrar.register(candidate) { [weak self] in
                self?.onShortcutPressed?()
            }
        } catch {
            message = ScrollingCaptureShortcutError.conflict.errorDescription
            throw ScrollingCaptureShortcutError.conflict
        }

        activeRegistration?.invalidate()
        activeRegistration = registration
        try preferences.save(candidate)
        shortcut = candidate
        message = nil
    }

    func clear() {
        activeRegistration?.invalidate()
        activeRegistration = nil
        preferences.clear()
        shortcut = nil
        message = nil
    }
}

/// One registrar for the whole app: every registrar installs its own Carbon
/// handler and numbers its hot keys from 1, so a second one would see the
/// first one's presses and swallow them.
@MainActor
final class CarbonGlobalHotKeyRegistrar: NSObject, GlobalHotKeyRegistering {
    static let shared = CarbonGlobalHotKeyRegistrar()
    private static let signature = OSType(0x4C534350) // "LSCP"
    private var eventHandler: EventHandlerRef?
    private var pressHandlers: [UInt32: () -> Void] = [:]
    private var nextIdentifier: UInt32 = 1

    private override init() {
        super.init()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.hotKeyPressed,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(
        _ shortcut: ScrollingCaptureShortcut,
        onPress: @escaping () -> Void
    ) throws -> any GlobalHotKeyRegistration {
        let identifier = nextIdentifier
        nextIdentifier &+= 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            throw ScrollingCaptureShortcutError.conflict
        }

        pressHandlers[identifier] = onPress
        return CarbonHotKeyRegistration(hotKeyRef: hotKeyRef) { [weak self] in
            self?.pressHandlers.removeValue(forKey: identifier)
        }
    }

    private func deliverPress(from event: EventRef?) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else {
            return status
        }
        guard let onPress = pressHandlers[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        onPress()
        return noErr
    }

    private static let hotKeyPressed: EventHandlerUPP = { _, event, userData in
        guard let userData else {
            return OSStatus(eventNotHandledErr)
        }
        let registrar = Unmanaged<CarbonGlobalHotKeyRegistrar>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return registrar.deliverPress(from: event)
    }
}

@MainActor
private final class CarbonHotKeyRegistration: GlobalHotKeyRegistration {
    private var hotKeyRef: EventHotKeyRef?
    private let onInvalidate: () -> Void

    init(hotKeyRef: EventHotKeyRef, onInvalidate: @escaping () -> Void) {
        self.hotKeyRef = hotKeyRef
        self.onInvalidate = onInvalidate
    }

    func invalidate() {
        guard let hotKeyRef else {
            return
        }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        onInvalidate()
    }

}
