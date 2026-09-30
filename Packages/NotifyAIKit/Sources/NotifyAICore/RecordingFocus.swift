//
//  RecordingFocus.swift
//  NotifyAICore
//

import Foundation

/// What kind of conversation a note contains. The focus steers what the summary
/// emphasises; it replaces the former template library.
public enum RecordingFocus: String, CaseIterable, Codable, Identifiable, Sendable {
    case general
    case meeting
    case lecture
    case interview
    case sales
    case oneOnOne

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .general: "text.bubble"
        case .meeting: "person.3"
        case .lecture: "graduationcap"
        case .interview: "person.2.wave.2"
        case .sales: "briefcase"
        case .oneOnOne: "person.line.dotted.person"
        }
    }

    /// Additional guidance for the language model. Written in English because the
    /// on-device model follows English instructions most reliably; the output
    /// language is set separately.
    public var modelGuidance: String {
        switch self {
        case .general:
            "Capture the main points in the order they were discussed."
        case .meeting:
            "Focus on decisions, agreed next steps with owners and deadlines, and unresolved issues."
        case .lecture:
            "Focus on concepts, definitions, explanations and anything that sounds exam-relevant."
        case .interview:
            "Focus on the interviewee's statements, needs, pain points and notable quotes."
        case .sales:
            "Focus on customer needs, objections, budget, timeline and agreed next steps."
        case .oneOnOne:
            "Focus on feedback, goals, personal development topics and agreed support."
        }
    }
}
