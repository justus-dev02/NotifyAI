//
//  Theme.swift
//  DesignSystem
//

import NotifyAICore
import SwiftUI

/// Design tokens. The app relies on system materials, colors and typography so it feels
/// native on iOS and macOS (including Liquid Glass); only a few values are defined here.
public enum Theme {
    public enum Spacing {
        public static let xSmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 20
        public static let xLarge: CGFloat = 32
    }

    public enum Radius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 14
        public static let large: CGFloat = 22
    }

    /// Maximum width of reading content, so long lines stay readable on wide windows.
    public static let readableWidth: CGFloat = 760

    /// Background of words and segments inside a marker window.
    public static let highlight = Color.yellow.opacity(0.32)
    public static let marker = Color.orange
    public static let recording = Color.red
}

extension NoteStatus {
    public var tint: Color {
        switch self {
        case .recording: Theme.recording
        case .queued, .transcribing, .identifyingSpeakers, .summarizing: .accentColor
        case .ready: .green
        case .failed: .orange
        }
    }

    public var symbolName: String {
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
