//
//  AudioSource.swift
//  NotifyAI
//

import Foundation

/// What a recording captures.
///
/// System audio (the sound other apps play, e.g. the participants of a Zoom, Teams or
/// Discord call) can only be recorded on the Mac, through Core Audio process taps.
enum RecordingAudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The microphone only: conversations in the room.
    case microphone
    /// Microphone and system audio mixed: online meetings, own voice included.
    case microphoneAndSystemAudio
    /// System audio only: webinars, videos, podcasts.
    case systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Mikrofon"
        case .microphoneAndSystemAudio: "Mikrofon + Systemton"
        case .systemAudio: "Nur Systemton"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            "Nimmt auf, was im Raum gesprochen wird."
        case .microphoneAndSystemAudio:
            "Für Online-Meetings: deine Stimme über das Mikrofon, die anderen Teilnehmenden direkt aus der App (z. B. Zoom, Teams, Discord)."
        case .systemAudio:
            "Nimmt nur den Ton von Apps auf, z. B. Webinare oder Videos. Das Mikrofon bleibt aus."
        }
    }

    var symbolName: String {
        switch self {
        case .microphone: "mic"
        case .microphoneAndSystemAudio: "person.2.wave.2"
        case .systemAudio: "speaker.wave.2"
        }
    }

    var usesMicrophone: Bool { self != .systemAudio }
    var usesSystemAudio: Bool { self != .microphone }

    /// Sources this platform can record. iOS does not allow capturing other apps' audio.
    static var available: [RecordingAudioSource] {
        #if os(macOS)
        allCases
        #else
        [.microphone]
        #endif
    }
}

/// Which apps' audio a system audio recording captures.
enum SystemAudioTarget: Codable, Hashable, Sendable {
    /// Everything the Mac plays, except NotifyAI itself.
    case allApps
    /// One app including its helper processes (browsers and Electron apps play audio from helpers).
    case app(bundleID: String, name: String)

    var displayName: String {
        switch self {
        case .allApps: "Alle Apps"
        case .app(_, let name): name
        }
    }

    var bundleID: String? {
        switch self {
        case .allApps: nil
        case .app(let bundleID, _): bundleID
        }
    }
}

// MARK: - Source activity

/// Loudness of the microphone and of the system audio in fixed time bins, recorded
/// alongside a "Mikrofon + Systemton" recording.
///
/// The two sources are mixed into one file, but their levels are kept separately. This
/// tells the user ("Ich", microphone) apart from the other participants ("Andere",
/// system audio) far more reliably than guessing from voices. Bins lie on the recording
/// timeline (pauses excluded), like transcript and marker times.
struct SourceActivity: Codable, Equatable, Sendable {
    static let binDuration: TimeInterval = 0.1
    /// Levels are stored as dBFS + `levelOffset`, clamped to 0…255: one byte per bin.
    private static let levelOffset: Float = 100

    private var microphoneBytes: Data
    private var systemBytes: Data

    /// - Parameters: Levels per bin in dBFS. Both arrays must have the same length.
    init(microphoneLevels: [Float], systemLevels: [Float]) {
        precondition(microphoneLevels.count == systemLevels.count, "Both sources need one level per bin")
        microphoneBytes = Data(microphoneLevels.map(Self.encode))
        systemBytes = Data(systemLevels.map(Self.encode))
    }

    var binCount: Int { microphoneBytes.count }

    /// Level of bin `index` in dBFS (−100 means silence).
    func microphoneLevel(at index: Int) -> Float { Self.decode(microphoneBytes[microphoneBytes.startIndex + index]) }
    func systemLevel(at index: Int) -> Float { Self.decode(systemBytes[systemBytes.startIndex + index]) }

    var microphoneLevels: [Float] { microphoneBytes.map(Self.decode) }
    var systemLevels: [Float] { systemBytes.map(Self.decode) }

    /// Bins overlapping `start..<end`, clamped to the recorded range.
    func bins(from start: TimeInterval, to end: TimeInterval) -> Range<Int> {
        let lower = max(0, Int((start / Self.binDuration).rounded(.down)))
        let upper = min(binCount, Int((end / Self.binDuration).rounded(.up)))
        return lower..<max(lower, upper)
    }

    private static func encode(_ level: Float) -> UInt8 {
        guard level.isFinite else { return 0 }
        return UInt8(min(255, max(0, (level + levelOffset).rounded())))
    }

    private static func decode(_ byte: UInt8) -> Float {
        Float(byte) - levelOffset
    }
}

/// Collects the per-bin energy of both sources while recording.
///
/// Bins are addressed by the absolute frame position on the recording timeline, so
/// blocks of any size can be appended.
struct SourceActivityRecorder: Sendable {
    private let samplesPerBin = Int(AudioFormat.sampleRate * SourceActivity.binDuration)
    private var microphoneEnergy: [Double] = []
    private var systemEnergy: [Double] = []
    private var sampleCounts: [Int] = []

    /// Appends one block. `microphone` and `system` must have the same length.
    mutating func append(microphone: ArraySlice<Float>, system: ArraySlice<Float>, startFrame: Int64) {
        precondition(microphone.count == system.count, "Both sources need the same number of samples")
        var frame = Int(startFrame)
        for (mic, sys) in zip(microphone, system) {
            let bin = frame / samplesPerBin
            while sampleCounts.count <= bin {
                microphoneEnergy.append(0)
                systemEnergy.append(0)
                sampleCounts.append(0)
            }
            microphoneEnergy[bin] += Double(mic * mic)
            systemEnergy[bin] += Double(sys * sys)
            sampleCounts[bin] += 1
            frame += 1
        }
    }

    var isEmpty: Bool { sampleCounts.isEmpty }

    func makeActivity() -> SourceActivity {
        func levels(_ energy: [Double]) -> [Float] {
            zip(energy, sampleCounts).map { sum, count in
                guard count > 0, sum > 0 else { return -100 }
                return Float(10 * log10(sum / Double(count)))
            }
        }
        return SourceActivity(microphoneLevels: levels(microphoneEnergy), systemLevels: levels(systemEnergy))
    }
}

// MARK: - Speaker attribution

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

    static let userLabel = "Ich"
    static let defaultOthersLabel = "Andere"

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
