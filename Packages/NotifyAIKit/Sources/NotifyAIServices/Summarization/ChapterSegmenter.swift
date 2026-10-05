//
//  ChapterSegmenter.swift
//  NotifyAIServices
//

import CryptoKit
import Foundation
import NotifyAICore

/// A chapter of a transcript, ready to be summarized.
struct TranscriptChapter: Equatable, Sendable {
    /// Indices into the segments the chapter was cut from.
    let segmentRange: Range<Int>
    let start: TimeInterval
    let end: TimeInterval
    /// Transcript text with speaker labels, as the summarizer receives it.
    let text: String
    /// Identifies the chapter's content: same boundaries and same words give the same key.
    /// Speaker labels are left out, so a digest made while recording (before speakers were
    /// assigned) is still reused afterwards.
    let key: String
}

/// Cuts long transcripts into chapters of about ten minutes, preferably where the topic
/// changes.
///
/// A boundary is chosen among the segment starts between `minimumDuration` and
/// `maximumDuration` after the chapter start. For each candidate, the words of the
/// `cohesionWindow` before and after it are compared (lexical cohesion, as in TextTiling):
/// the lower the overlap, the more likely the topic changes there. Longer pauses count as
/// an additional hint.
///
/// **Determinism:** a chapter is only closed when the transcript reaches beyond its latest
/// possible boundary plus the cohesion window. The decision therefore depends only on
/// segments that already exist, and cutting while recording (`isComplete == false`) yields
/// exactly the chapters that cutting the finished transcript yields. Summaries made during
/// the recording are reused one to one.
struct ChapterSegmenter: Sendable {
    var minimumDuration: TimeInterval = 7 * 60
    var targetDuration: TimeInterval = 10 * 60
    var maximumDuration: TimeInterval = 13 * 60
    var cohesionWindow: TimeInterval = 90
    /// Shorter recordings fit into a single summary and get no chapters.
    var minimumRecordingDuration: TimeInterval = 20 * 60
    /// A shorter rest at the end is added to the last chapter.
    var minimumFinalChapter: TimeInterval = 3 * 60

    func chapters(in segments: [TranscriptSegment], isComplete: Bool, languageCode: String) -> [TranscriptChapter] {
        guard let first = segments.first, let last = segments.last else { return [] }
        if isComplete, last.end - first.start < minimumRecordingDuration { return [] }

        let terms = segments.map { Set(TextAnalysis.terms(in: $0.text, languageCode: languageCode)) }
        var ranges: [Range<Int>] = []
        var startIndex = 0

        while startIndex < segments.count {
            let chapterStart = segments[startIndex].start
            let decisionHorizon = chapterStart + maximumDuration + cohesionWindow

            guard last.end >= decisionHorizon else {
                // Not enough transcript to decide the boundary yet.
                if isComplete {
                    let rest = startIndex..<segments.count
                    let restDuration = last.end - chapterStart
                    if restDuration < minimumFinalChapter, let previous = ranges.popLast() {
                        ranges.append(previous.lowerBound..<segments.count)
                    } else {
                        ranges.append(rest)
                    }
                }
                break
            }

            let boundary = bestBoundary(after: startIndex, chapterStart: chapterStart, segments: segments, terms: terms)
            ranges.append(startIndex..<boundary)
            startIndex = boundary
        }

        return ranges.map { makeChapter($0, segments: segments) }
    }

    // MARK: - Boundary

    private func bestBoundary(after startIndex: Int, chapterStart: TimeInterval, segments: [TranscriptSegment], terms: [Set<String>]) -> Int {
        let earliest = chapterStart + minimumDuration
        let latest = chapterStart + maximumDuration
        let candidates = ((startIndex + 1)..<segments.count).filter { segments[$0].start >= earliest && segments[$0].start <= latest }
        guard !candidates.isEmpty else {
            // No segment starts inside the window (a very long segment): cut after it.
            return ((startIndex + 1)..<segments.count).first { segments[$0].start > latest } ?? segments.count
        }

        var best = candidates[0]
        var bestScore = Double.infinity
        for candidate in candidates {
            let boundaryTime = segments[candidate].start
            let before = words(in: segments, terms: terms, from: boundaryTime - cohesionWindow, to: boundaryTime)
            let after = words(in: segments, terms: terms, from: boundaryTime, to: boundaryTime + cohesionWindow)
            let cohesion = Self.cosine(before, after)
            let pause = min(max(0, boundaryTime - segments[candidate - 1].end), 5) / 5
            // Slight preference for the target length among equally good candidates.
            let lengthPenalty = abs(boundaryTime - chapterStart - targetDuration) / maximumDuration * 0.05
            let score = cohesion - 0.2 * pause + lengthPenalty
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /// Term frequencies of all segments that start inside `from..<to`.
    private func words(in segments: [TranscriptSegment], terms: [Set<String>], from: TimeInterval, to: TimeInterval) -> [String: Double] {
        var counts: [String: Double] = [:]
        for (index, segment) in segments.enumerated() where segment.start >= from && segment.start < to {
            for term in terms[index] {
                counts[term, default: 0] += 1
            }
        }
        return counts
    }

    static func cosine(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let dot = lhs.reduce(0.0) { $0 + $1.value * (rhs[$1.key] ?? 0) }
        let lhsLength = lhs.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let rhsLength = rhs.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return dot / (lhsLength * rhsLength)
    }

    // MARK: - Chapter

    private func makeChapter(_ range: Range<Int>, segments: [TranscriptSegment]) -> TranscriptChapter {
        let slice = Array(segments[range])
        let start = slice.first?.start ?? 0
        let end = slice.last?.end ?? start
        var hasher = SHA256()
        hasher.update(data: Data("\(Int(start * 100))|\(Int(end * 100))".utf8))
        for segment in slice {
            hasher.update(data: Data(segment.text.utf8))
            hasher.update(data: Data([0]))
        }
        return TranscriptChapter(
            segmentRange: range,
            start: start,
            end: end,
            text: Transcript.plainText(of: slice),
            key: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
