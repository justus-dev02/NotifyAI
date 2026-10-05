//
//  SourceSpeakerAttribution.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore

/// Labels transcript passages as spoken by the user (microphone) or by the other
/// participants (system audio), based on `SourceActivity`.
///
/// Rules per 100 ms bin:
/// - System audio clearly above its noise floor → the others are speaking. This also holds
///   when the Mac's speakers leak into the microphone: the system audio itself is the clean
///   reference, so echo in the microphone does not turn remote speech into "Ich".
/// - Otherwise the microphone clearly above its noise floor → the user is speaking.
/// - Otherwise silence, which does not vote.
///
/// Segments with word timings are split at speaker changes, so a phrase that contains a
/// quick reply of the other side is divided correctly.
enum SourceSpeakerAttribution {
    enum Speaker: Equatable, Sendable {
        case user
        case others
    }

    static let userLabel = String(localized: "Ich", bundle: .module)
    static let defaultOthersLabel = String(localized: "Andere", bundle: .module)

    struct Configuration: Sendable {
        /// A bin is active when it is this far above the source's noise floor …
        var activationMarginDB: Float = 12
        /// … and above this absolute level.
        var minimumLevelDB: Float = -55
        /// The threshold never exceeds this level. Without the cap, a recording without pauses
        /// would put the "noise floor" at speech level and treat all speech as silence.
        var maximumThresholdDB: Float = -40
        /// Speaker runs shorter than this (in words and seconds) between two runs of the other
        /// speaker are treated as misclassified and merged.
        var minimumRunWords = 2
        var minimumRunDuration: TimeInterval = 0.6
    }

    /// The label for the other side: the participant's name if exactly one was entered.
    static func othersLabel(participants: [String]) -> String {
        participants.count == 1 ? participants[0] : defaultOthersLabel
    }

    /// The speaker of every bin, `nil` for silence.
    static func classify(_ activity: SourceActivity, configuration: Configuration = Configuration()) -> [Speaker?] {
        guard activity.binCount > 0 else { return [] }
        let microphone = activity.microphoneLevels
        let system = activity.systemLevels
        let microphoneThreshold = threshold(for: microphone, configuration: configuration)
        let systemThreshold = threshold(for: system, configuration: configuration)
        return (0..<activity.binCount).map { index in
            if system[index] > systemThreshold { return .others }
            if microphone[index] > microphoneThreshold { return .user }
            return nil
        }
    }

    static func assign(
        _ activity: SourceActivity,
        to segments: [TranscriptSegment],
        othersLabel: String = defaultOthersLabel,
        configuration: Configuration = Configuration()
    ) -> [TranscriptSegment] {
        let speakers = classify(activity, configuration: configuration)
        guard !speakers.isEmpty else { return segments }

        func label(_ speaker: Speaker) -> String {
            speaker == .user ? userLabel : othersLabel
        }

        var result: [TranscriptSegment] = []
        for segment in segments {
            guard !segment.words.isEmpty else {
                var updated = segment
                if let speaker = majority(in: activity.bins(from: segment.start, to: segment.end), of: speakers) {
                    updated.speaker = label(speaker)
                }
                result.append(updated)
                continue
            }

            let wordSpeakers = smoothed(
                filled(segment.words.map { majority(in: activity.bins(from: $0.start, to: $0.end), of: speakers) }),
                words: segment.words,
                configuration: configuration
            )
            for (index, run) in runs(of: wordSpeakers).enumerated() {
                let words = Array(segment.words[run.range])
                var part = TranscriptSegment(
                    id: index == 0 ? segment.id : UUID(),
                    start: index == 0 ? segment.start : words[0].start,
                    end: run.range.upperBound == segment.words.count ? segment.end : words[words.count - 1].end,
                    text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                    speaker: segment.speaker,
                    words: words
                )
                if let speaker = run.speaker {
                    part.speaker = label(speaker)
                }
                result.append(part)
            }
        }
        return result
    }

    // MARK: Helpers

    /// Noise floor = 10th percentile of all bins; active speech must clearly exceed it.
    private static func threshold(for levels: [Float], configuration: Configuration) -> Float {
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let adaptive = min(floor + configuration.activationMarginDB, configuration.maximumThresholdDB)
        return max(adaptive, configuration.minimumLevelDB)
    }

    private static func majority(in bins: Range<Int>, of speakers: [Speaker?]) -> Speaker? {
        var user = 0
        var others = 0
        for index in bins {
            switch speakers[index] {
            case .user: user += 1
            case .others: others += 1
            case nil: break
            }
        }
        if user == 0, others == 0 { return nil }
        return others >= user ? .others : .user
    }

    /// Words in silent bins (e.g. very short words) take the speaker of the previous word,
    /// or of the next one at the start of a segment.
    private static func filled(_ speakers: [Speaker?]) -> [Speaker?] {
        var result = speakers
        var previous: Speaker?
        for index in result.indices {
            if let speaker = result[index] {
                previous = speaker
            } else {
                result[index] = previous
            }
        }
        var next: Speaker?
        for index in result.indices.reversed() {
            if let speaker = result[index] {
                next = speaker
            } else {
                result[index] = next
            }
        }
        return result
    }

    /// Merges short runs that sit between two runs of the same other speaker.
    private static func smoothed(_ speakers: [Speaker?], words: [TranscriptWord], configuration: Configuration) -> [Speaker?] {
        var result = speakers
        let allRuns = runs(of: speakers)
        guard allRuns.count >= 3 else { return result }
        for index in 1..<(allRuns.count - 1) {
            let run = allRuns[index]
            let before = allRuns[index - 1]
            let after = allRuns[index + 1]
            guard before.speaker == after.speaker, before.speaker != run.speaker else { continue }
            let duration = words[run.range.upperBound - 1].end - words[run.range.lowerBound].start
            if run.range.count < configuration.minimumRunWords, duration < configuration.minimumRunDuration {
                for wordIndex in run.range {
                    result[wordIndex] = before.speaker
                }
            }
        }
        return result
    }

    private struct Run {
        var speaker: Speaker?
        var range: Range<Int>
    }

    private static func runs(of speakers: [Speaker?]) -> [Run] {
        var runs: [Run] = []
        for (index, speaker) in speakers.enumerated() {
            if let last = runs.last, last.speaker == speaker {
                runs[runs.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                runs.append(Run(speaker: speaker, range: index..<(index + 1)))
            }
        }
        return runs
    }
}
