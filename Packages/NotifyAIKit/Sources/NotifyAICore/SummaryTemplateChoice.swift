//
//  SummaryTemplateChoice.swift
//  NotifyAICore
//

import Foundation

/// How a note is summarized: one of the built-in kinds of conversation or a template of the
/// user's own.
public enum SummaryTemplateChoice: Hashable, Sendable {
    case focus(RecordingFocus)
    case custom(UUID)

    /// "focus.meeting" or "custom.<UUID>", for the settings.
    package var storageValue: String {
        switch self {
        case .focus(let focus): "focus.\(focus.rawValue)"
        case .custom(let id): "custom.\(id.uuidString)"
        }
    }

    package init?(storageValue: String) {
        let parts = storageValue.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "focus":
            guard let focus = RecordingFocus(rawValue: parts[1]) else { return nil }
            self = .focus(focus)
        case "custom":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .custom(id)
        default:
            return nil
        }
    }
}
