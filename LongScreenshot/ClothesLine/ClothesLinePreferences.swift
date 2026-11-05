//
//  ClothesLinePreferences.swift
//  LongScreenshot
//

import Foundation

/// Whether finished captures hang on the clothesline after they are saved.
/// Off by default, so saving behaves exactly as before until it is turned on.
nonisolated struct ClothesLinePreferences {
    private enum Keys {
        static let isEnabled = "clothes_line_enabled"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        get { userDefaults.bool(forKey: Keys.isEnabled) }
        nonmutating set { userDefaults.set(newValue, forKey: Keys.isEnabled) }
    }
}
