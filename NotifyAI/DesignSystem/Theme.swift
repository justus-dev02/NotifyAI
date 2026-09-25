//
//  Theme.swift
//  NotifyAI
//

import SwiftUI

/// Design tokens. The app relies on system materials, colors and typography so it feels
/// native on iOS and macOS (including Liquid Glass); only a few values are defined here.
enum Theme {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 14
        static let large: CGFloat = 22
    }

    /// Maximum width of reading content, so long lines stay readable on wide windows.
    static let readableWidth: CGFloat = 760

    /// Background of words and segments inside a marker window.
    static let highlight = Color.yellow.opacity(0.32)
    static let marker = Color.orange
    static let recording = Color.red
}

extension NoteStatus {
    var tint: Color {
        switch self {
        case .recording: Theme.recording
        case .queued, .transcribing, .identifyingSpeakers, .summarizing: .accentColor
        case .ready: .green
        case .failed: .orange
        }
    }

    var symbolName: String {
        switch self {
        case .recording: "record.circle"
        case .queued: "clock"
        case .transcribing: "waveform"
        case .identifyingSpeakers: "person.2.wave.2"
        case .summarizing: "sparkles"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}
