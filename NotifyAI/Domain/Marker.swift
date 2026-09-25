//
//  Marker.swift
//  NotifyAI
//

import Foundation

/// A moment the user flagged as important ("Wichtig") while recording or listening.
struct Marker: Identifiable, Codable, Hashable, Sendable {
    /// How far before and after the marker the transcript is highlighted.
    static let highlightPadding: TimeInterval = 5

    var id: UUID
    /// Position on the recording timeline in seconds.
    var time: TimeInterval
    var createdAt: Date

    init(id: UUID = UUID(), time: TimeInterval, createdAt: Date = .now) {
        self.id = id
        self.time = max(0, time)
        self.createdAt = createdAt
    }

    /// The highlighted window around the marker, clamped to the recording.
    func highlightRange(duration: TimeInterval? = nil) -> ClosedRange<TimeInterval> {
        let lower = max(0, time - Self.highlightPadding)
        var upper = time + Self.highlightPadding
        if let duration, duration > 0 {
            upper = min(upper, max(duration, lower))
        }
        return lower...max(lower, upper)
    }
}

/// The set of highlighted time windows for a list of markers.
///
/// Overlapping windows are merged, so lookups are a binary search over disjoint,
/// sorted ranges. This keeps highlighting cheap even for long transcripts.
struct HighlightWindows: Equatable, Sendable {
    private(set) var ranges: [ClosedRange<TimeInterval>]

    init(markers: [Marker], duration: TimeInterval? = nil) {
        let sorted = markers
            .map { $0.highlightRange(duration: duration) }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }

    var isEmpty: Bool { ranges.isEmpty }

    /// Whether any part of `range` lies inside a highlighted window.
    func intersects(_ range: ClosedRange<TimeInterval>) -> Bool {
        // Find the first window whose upper bound reaches the start of `range`.
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound < range.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].lowerBound <= range.upperBound
    }

    /// Whether a word is highlighted. A word counts as highlighted when its midpoint lies
    /// inside a window, so words that only graze the border are not coloured.
    func contains(_ word: TranscriptWord) -> Bool {
        let midpoint = (word.start + max(word.start, word.end)) / 2
        return intersects(midpoint...midpoint)
    }
}
