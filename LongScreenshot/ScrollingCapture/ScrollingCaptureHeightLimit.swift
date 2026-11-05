//
//  ScrollingCaptureHeightLimit.swift
//  LongScreenshot
//

import Foundation

enum ScrollingCaptureHeightLimit {
    /// PNG allows far taller images, but past this the export cost and the
    /// usefulness of the result both fall off a cliff.
    static let maximumHeight = 30_000
}
