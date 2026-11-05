//
//  ScrollingCaptureShortcutPreferences.swift
//  LongScreenshot
//

import Foundation

final class ScrollingCaptureShortcutPreferences {
    private enum Keys {
        static let shortcut = "scrolling_capture_shortcut"
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() throws -> ScrollingCaptureShortcut? {
        guard let data = userDefaults.data(forKey: Keys.shortcut) else {
            return nil
        }
        return try decoder.decode(ScrollingCaptureShortcut.self, from: data)
    }

    func save(_ shortcut: ScrollingCaptureShortcut) throws {
        userDefaults.set(try encoder.encode(shortcut), forKey: Keys.shortcut)
    }

    func clear() {
        userDefaults.removeObject(forKey: Keys.shortcut)
    }
}
