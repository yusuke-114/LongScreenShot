//
//  ScrollingCaptureSaveFolderPreferences.swift
//  LongScreenshot
//

import Foundation

enum ScrollingCaptureSaveFolderError: LocalizedError {
    case authorizationRequired
    case authorizationExpired

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return String(localized: "Choose a save folder to allow Long Screenshot to export the scrolling screenshot.")
        case .authorizationExpired:
            return String(localized: "The permission for the selected save folder has expired. Choose the folder again.")
        }
    }
}

final class ScrollingCaptureSaveFolderPreferences: @unchecked Sendable {
    private enum Keys {
        static let folderBookmark = "scrolling_capture_save_folder_bookmark"
    }

    private let userDefaults: UserDefaults
    private let makeBookmark: (URL) throws -> Data
    private let resolveBookmark: (Data) throws -> URL

    init(
        userDefaults: UserDefaults = .standard,
        makeBookmark: @escaping (URL) throws -> Data = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: @escaping (Data) throws -> URL = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                throw ScrollingCaptureSaveFolderError.authorizationExpired
            }
            return url
        }
    ) {
        self.userDefaults = userDefaults
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
    }

    func save(folder: URL) throws {
        userDefaults.set(try makeBookmark(folder), forKey: Keys.folderBookmark)
    }

    func authorizedFolder() throws -> URL? {
        guard let bookmark = userDefaults.data(forKey: Keys.folderBookmark) else {
            return nil
        }
        return try resolveBookmark(bookmark)
    }
}
