//
//  SpeakerAttribution.swift
//  NotifyAISpeakers
//

import Foundation
import NotifyAICore
import NotifyAISupport

/// Labels every word of a transcript with its speaker and splits segments where the speaker
/// changes. Combines three sources of evidence:
///
/// 1. The audio source of a "Mikrofon + Systemton" recording (`SourceActivity`): microphone
///    → "Ich", system audio → the other side. This is the most reliable evidence and wins.
/// 2. Speaker detection (`Diarization`): which voice speaks when. On the other side of a call
///    it tells the remote participants apart; without an audio source it is all there is.
/// 3. Recognized voices (`VoiceRecognition.Match`): a detected voice the user named before
///    gets that name ("Anna"); the user's own voice is "Ich".
///
/// Unrecognized voices are numbered by their first appearance in the result ("Sprecher 1",
/// "Sprecher 2"); a single unrecognized voice without an audio source gets no label, since
/// there is nobody to tell it apart from. Short runs between two runs of the same speaker
/// (a misclassified word) are merged.
package enum SpeakerAttribution {
    package struct Evidence: Sendable {
        package var diarization: Diarization?
        package var matches: [Int: VoiceRecognition.Match] = [:]
        var activity: SourceActivity?
        /// The label for the other side when no voice tells them apart.
        package var othersLabel: String

        package init(
            diarization: Diarization? = nil,
            matches: [Int: VoiceRecognition.Match] = [:],
            activity: SourceActivity? = nil,
            othersLabel: String = SpeakerLabels.others
        ) {
            self.diarization = diarization
            self.matches = matches
            self.activity = activity
            self.othersLabel = othersLabel
        }
    }

    package struct Result: Sendable {
        package var segments: [TranscriptSegment]
        package var speakers: [NoteSpeaker]
    }

    /// Who speaks a word, before it is turned into a label.
    enum Key: Hashable, Sendable {
        case user
        case others
        case voice(Int)
    }

    package static func attribute(
        _ segments: [TranscriptSegment],
        evidence: Evidence,
        configuration: SourceSpeakerAttribution.Configuration = .init()
    ) -> Result {
        let labeler = WordLabeler(evidence: evidence, configuration: configuration)
        guard labeler.hasEvidence else { return Result(segments: segments, speakers: []) }

        var keyed: [(segment: TranscriptSegment, key: Key?)] = []
        for segment in segments {
            guard !segment.words.isEmpty else {
                keyed.append((segment, labeler.key(from: segment.start, to: segment.end)))
                continue
            }
            let keys = SpeakerRuns.smoothed(
                SpeakerRuns.filled(segment.words.map { labeler.key(from: $0.start, to: $0.end) }),
                words: segment.words,
                minimumWords: configuration.minimumRunWords,
                minimumDuration: configuration.minimumRunDuration
            )
            for part in SpeakerRuns.split(segment, keys: keys) {
                keyed.append(part)
            }
        }
        let names = labeler.names(for: keyed.compactMap(\.key))
        let labeled = keyed.map { item -> TranscriptSegment in
            var segment = item.segment
            if let key = item.key, let name = names[key] {
                segment.speaker = name
            }
            return segment
        }
        return Result(segments: labeled, speakers: labeler.speakers(for: keyed, names: names))
    }
}

// MARK: - Word labels

/// The evidence for one recording, queried per word.
private struct WordLabeler {
    let evidence: SpeakerAttribution.Evidence
    let sourceSpeakers: [SourceSpeakerAttribution.Speaker?]
    let turns: [SpeakerTurn]
    /// Whether detected voices may label words without an audio source: two or more voices,
    /// or one recognized voice.
    let labelsVoices: Bool

    package init(evidence: SpeakerAttribution.Evidence, configuration: SourceSpeakerAttribution.Configuration) {
        self.evidence = evidence
        sourceSpeakers = evidence.activity.map { SourceSpeakerAttribution.classify($0, configuration: configuration) } ?? []
        turns = evidence.diarization?.turns ?? []
        let voices = Set(turns.map(\.speaker))
        labelsVoices = voices.count >= 2 || voices.contains { evidence.matches[$0] != nil }
    }

    var hasEvidence: Bool { !sourceSpeakers.isEmpty || (labelsVoices && !turns.isEmpty) }

    /// The speaker of `start..<end`, or `nil` if nothing speaks there.
    func key(from start: TimeInterval, to end: TimeInterval) -> SpeakerAttribution.Key? {
        let voice = dominantVoice(from: start, to: end)
        switch source(from: start, to: end) {
        case .user:
            return .user
        case .others:
            // The other side is told apart by voice, unless the voice is the user's own
            // (echo of the user in the system audio, or a misdetection).
            if let voice, evidence.matches[voice]?.isUser != true {
                return .voice(voice)
            }
            return .others
        case nil:
            guard sourceSpeakers.isEmpty, labelsVoices, let voice else { return nil }
            return evidence.matches[voice]?.isUser == true ? .user : .voice(voice)
        }
    }

    private func source(from start: TimeInterval, to end: TimeInterval) -> SourceSpeakerAttribution.Speaker? {
        guard let activity = evidence.activity, !sourceSpeakers.isEmpty else { return nil }
        var user = 0
        var others = 0
        for index in activity.bins(from: start, to: end) {
            switch sourceSpeakers[index] {
            case .user: user += 1
            case .others: others += 1
            case nil: break
            }
        }
        if user == 0, others == 0 { return nil }
        return others >= user ? .others : .user
    }

    /// The voice with the largest overlap with `start..<end`.
    func dominantVoice(from start: TimeInterval, to end: TimeInterval) -> Int? {
        var overlap: [Int: TimeInterval] = [:]
        let end = max(end, start + 0.01)
        for turn in turns where turn.end > start && turn.start < end {
            overlap[turn.speaker, default: 0] += min(turn.end, end) - max(turn.start, start)
        }
        return overlap.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// The label of every key that occurs. Unrecognized voices are numbered in the order
    /// they first appear.
    func names(for keys: [SpeakerAttribution.Key]) -> [SpeakerAttribution.Key: String] {
        var names: [SpeakerAttribution.Key: String] = [
            .user: SpeakerLabels.user,
            .others: evidence.othersLabel,
        ]
        var number = 0
        for key in keys where names[key] == nil {
            guard case .voice(let voice) = key else { continue }
            if let match = evidence.matches[voice] {
                names[key] = match.isUser ? SpeakerLabels.user : match.name
            } else {
                number += 1
                names[key] = SpeakerLabels.detected(number)
            }
        }
        return names
    }

    /// One speaker per label, in order of first appearance, with the voice print of the
    /// detected voice that speaks most of it.
    package func speakers(
        for keyed: [(segment: TranscriptSegment, key: SpeakerAttribution.Key?)],
        names: [SpeakerAttribution.Key: String]
    ) -> [NoteSpeaker] {
        var order: [String] = []
        var durations: [String: TimeInterval] = [:]
        var voiceTime: [String: [Int: TimeInterval]] = [:]
        var keys: [String: SpeakerAttribution.Key] = [:]
        for item in keyed {
            guard let key = item.key, let label = names[key] else { continue }
            if durations[label] == nil { order.append(label) }
            let duration = item.segment.end - item.segment.start
            durations[label, default: 0] += duration
            if keys[label] == nil { keys[label] = key }
            if let voice = dominantVoice(from: item.segment.start, to: item.segment.end) {
                voiceTime[label, default: [:]][voice, default: 0] += duration
            }
        }
        return order.map { label in
            let key = keys[label] ?? .others
            let voice: Int? = if case .voice(let index) = key { index } else {
                voiceTime[label]?.max { $0.value < $1.value }?.key
            }
            let match = voice.flatMap { evidence.matches[$0] }
            // Only a voice of this label may lend its print: never the other side's to "Ich".
            let print = voice.flatMap { voice in
                key == .others || (key == .user && match.map { !$0.isUser } == true) ? nil : evidence.diarization?.voicePrints[voice]
            }
            return NoteSpeaker(
                label: label,
                origin: origin(of: key, match: match),
                voicePrint: print,
                speechDuration: durations[label] ?? 0,
                profileID: match.flatMap { key == .user && !$0.isUser ? nil : $0.profileID },
                similarity: match.flatMap { key == .user && !$0.isUser ? nil : $0.similarity }
            )
        }
    }

    private func origin(of key: SpeakerAttribution.Key, match: VoiceRecognition.Match?) -> NoteSpeaker.Origin {
        switch key {
        case .user: match?.isUser == true ? .recognized : (sourceSpeakers.isEmpty ? .recognized : .audioSource)
        case .others: .audioSource
        case .voice: match == nil ? .detected : .recognized
        }
    }
}

// MARK: - Runs

/// Splitting segments into runs of one speaker, for any kind of speaker key.
enum SpeakerRuns {
    struct Run<Key: Hashable> {
        var key: Key?
        var range: Range<Int>
    }

    /// Words without a speaker (very short words in silent bins) take the speaker of the
    /// previous word, or of the next one at the start of a segment.
    static func filled<Key: Hashable>(_ keys: [Key?]) -> [Key?] {
        var result = keys
        var previous: Key?
        for index in result.indices {
            if let key = result[index] {
                previous = key
            } else {
                result[index] = previous
            }
        }
        var next: Key?
        for index in result.indices.reversed() {
            if let key = result[index] {
                next = key
            } else {
                result[index] = next
            }
        }
        return result
    }

    /// Merges short runs that sit between two runs of the same other speaker.
    static func smoothed<Key: Hashable>(_ keys: [Key?], words: [TranscriptWord], minimumWords: Int, minimumDuration: TimeInterval) -> [Key?] {
        var result = keys
        let all = runs(of: keys)
        guard all.count >= 3 else { return result }
        for index in 1..<(all.count - 1) {
            let run = all[index]
            let before = all[index - 1]
            let after = all[index + 1]
            guard before.key == after.key, before.key != run.key else { continue }
            let duration = words[run.range.upperBound - 1].end - words[run.range.lowerBound].start
            if run.range.count < minimumWords, duration < minimumDuration {
                for wordIndex in run.range {
                    result[wordIndex] = before.key
                }
            }
        }
        return result
    }

    static func runs<Key: Hashable>(of keys: [Key?]) -> [Run<Key>] {
        var runs: [Run<Key>] = []
        for (index, key) in keys.enumerated() {
            if let last = runs.last, last.key == key {
                runs[runs.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                runs.append(Run(key: key, range: index..<(index + 1)))
            }
        }
        return runs
    }

    /// The segment cut into one part per run of `keys` (one key per word). The first part
    /// keeps the segment's identity and start, the last its end.
    static func split<Key: Hashable>(_ segment: TranscriptSegment, keys: [Key?]) -> [(segment: TranscriptSegment, key: Key?)] {
        runs(of: keys).enumerated().map { index, run in
            let words = Array(segment.words[run.range])
            let part = TranscriptSegment(
                id: index == 0 ? segment.id : UUID(),
                start: index == 0 ? segment.start : words[0].start,
                end: run.range.upperBound == segment.words.count ? segment.end : words[words.count - 1].end,
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: segment.speaker,
                words: words
            )
            return (part, run.key)
        }
    }
}
