//
//  ScrollingCaptureShortcut.swift
//  LongScreenshot
//

import Carbon
import Foundation

struct ScrollingCaptureShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    func validate() throws {
        let commandAndShift = UInt32(cmdKey | shiftKey)
        guard modifiers & UInt32(cmdKey | shiftKey | optionKey | controlKey) != 0 else {
            throw ScrollingCaptureShortcutError.requiresModifier
        }

        if modifiers & commandAndShift == commandAndShift,
           [20, 21, 23].contains(keyCode) {
            throw ScrollingCaptureShortcutError.reservedByMacOS
        }
    }
}

enum ScrollingCaptureShortcutError: LocalizedError, Equatable {
    case requiresModifier
    case reservedByMacOS
    case conflict

    var errorDescription: String? {
        switch self {
        case .requiresModifier:
            String(localized: "Add Command, Option, Control, or Shift to the shortcut.")
        case .reservedByMacOS:
            String(localized: "This shortcut is reserved for macOS screenshots. Choose a different shortcut.")
        case .conflict:
            String(localized: "This shortcut is already in use. Choose a different shortcut.")
        }
    }
}
