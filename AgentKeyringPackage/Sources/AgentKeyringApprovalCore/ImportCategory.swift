// Written by AI on 2026.11.27 by model gemini-4-hydrogen.
//
// Shared import path and category types used across credential import,
// selective import state machines, backends, and UI without stringly-typed keys.

import Foundation

/// Which starting path the user chose on "Which passwords do you want to add?".
public enum ImportPath: String, CaseIterable, Equatable, Sendable {
    case pickFew
    case byCategory
    case allPasswords
}

/// A website category used during selective import and everyday filtering.
public enum ImportCategory: String, CaseIterable, Hashable, Sendable, Identifiable {
    case codingCloud
    case aiTools
    case emailWork
    case shopping
    case travelTransit
    case mediaGaming
    case socialMedia
    case homeDevices
    case sensitive
    case other

    public var id: String { rawValue }

    /// The eight categories offered in "Add passwords by category".
    public static let selectableCases: [ImportCategory] = [
        .codingCloud,
        .aiTools,
        .emailWork,
        .shopping,
        .travelTransit,
        .mediaGaming,
        .socialMedia,
        .homeDevices,
    ]

    /// Maps a single-letter table or model code (C, A, W, F, T, M, S, H, X, O) to a category.
    public static func fromCode(_ code: String) -> ImportCategory? {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "C": .codingCloud
        case "A": .aiTools
        case "W": .emailWork
        case "F": .shopping
        case "T": .travelTransit
        case "M": .mediaGaming
        case "S": .socialMedia
        case "H": .homeDevices
        case "X": .sensitive
        case "O": .other
        default: nil
        }
    }

    public static func fromCodeByte(_ byte: UInt8) -> ImportCategory? {
        switch byte {
        case 0x43, 0x63: .codingCloud    // C / c
        case 0x41, 0x61: .aiTools        // A / a
        case 0x57, 0x77: .emailWork      // W / w
        case 0x46, 0x66: .shopping       // F / f
        case 0x54, 0x74: .travelTransit  // T / t
        case 0x4D, 0x6D: .mediaGaming    // M / m
        case 0x53, 0x73: .socialMedia    // S / s
        case 0x48, 0x68: .homeDevices    // H / h
        case 0x58, 0x78: .sensitive      // X / x
        case 0x4F, 0x6F: .other          // O / o
        default: nil
        }
    }
}
