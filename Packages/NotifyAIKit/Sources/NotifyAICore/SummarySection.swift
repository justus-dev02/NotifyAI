//
//  SummarySection.swift
//  NotifyAICore
//

import Foundation

/// The standard sections of a summary besides the overview. A summary template chooses which
/// of them are generated.
public enum SummarySection: String, CaseIterable, Codable, Identifiable, Sendable {
    case keyPoints
    case decisions
    case actionItems
    case openQuestions
    case topics

    public var id: String { rawValue }
}
