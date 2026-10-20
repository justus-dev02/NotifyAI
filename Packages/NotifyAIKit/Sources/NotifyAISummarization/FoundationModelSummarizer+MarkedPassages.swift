//
//  FoundationModelSummarizer+MarkedPassages.swift
//  NotifyAISummarization
//

import Foundation
import NotifyAICore
import OSLog

/// The passages the user marked, sent along with a summary within a fixed token budget.
extension FoundationModelSummarizer {
    /// The marked passages as a prompt section, limited to `markedPassageBudget` tokens so
    /// the request cannot exceed the context window.
    /// - Returns: The section (empty without passages), its size and how many non-empty
    ///   passages did not fit.
    func markedSection(_ passages: [String], limit: Int, measure: TextChunker.Measure) async -> (text: String, tokens: Int, omitted: Int) {
        let candidates = passages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return ("", 0, 0) }
        let header = "\n\nThe user marked these passages as important; make sure they are reflected:"
        var used = await measure(header)
        var lines: [String] = []
        for passage in candidates.prefix(limit) {
            let line = "\n- \(passage)"
            let size = await measure(line)
            guard used + size <= markedPassageBudget else { continue }
            lines.append(line)
            used += size
        }
        let omitted = candidates.count - lines.count
        if omitted > 0 {
            Logger.summarization.info("\(omitted, privacy: .public) marked passages did not fit into the request")
        }
        guard !lines.isEmpty else { return ("", 0, omitted) }
        return (header + lines.joined(), used, omitted)
    }
}
