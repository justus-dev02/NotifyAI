//
//  SourceSpeakerAttribution.swift
//  NotifyAISpeakers
//

import Foundation
import NotifyAICore
import NotifyAISupport

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
/// quick reply of the other side is divided correctly (`SpeakerAttribution`, which also
/// combines the audio source with speaker detection).
package enum SourceSpeakerAttribution {
    enum Speaker: Equatable, Sendable {
        case user
        case others
    }

    package struct Configuration: Sendable {
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
    package static func othersLabel(participants: [String]) -> String {
        participants.count == 1 ? participants[0] : SpeakerLabels.others
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

    /// The segments labelled "Ich" / the other side by audio source alone.
    static func assign(
        _ activity: SourceActivity,
        to segments: [TranscriptSegment],
        othersLabel: String = SpeakerLabels.others,
        configuration: Configuration = Configuration()
    ) -> [TranscriptSegment] {
        SpeakerAttribution.attribute(
            segments,
            evidence: SpeakerAttribution.Evidence(activity: activity, othersLabel: othersLabel),
            configuration: configuration
        ).segments
    }

    // MARK: Helpers

    /// Noise floor = 10th percentile of all bins; active speech must clearly exceed it.
    private static func threshold(for levels: [Float], configuration: Configuration) -> Float {
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let adaptive = min(floor + configuration.activationMarginDB, configuration.maximumThresholdDB)
        return max(adaptive, configuration.minimumLevelDB)
    }
}
