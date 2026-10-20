//
//  VoiceRecognition.swift
//  NotifyAISpeakers
//

import Foundation
import NotifyAICore
import NotifyAISupport

/// Puts names on the speakers of a recording by comparing their voice prints with the voices
/// the user named before.
///
/// Every speaker is compared with every profile (cosine similarity of the L2-normalized
/// voice prints). Pairs are assigned best first, each profile and each speaker at most once:
/// two speakers of one recording are two people, even if both resemble the same profile.
/// A name is only given above `threshold`; a wrong name is worse than none, and the user can
/// always name a speaker by hand.
package struct VoiceRecognition: Sendable {
    /// A named voice.
    package struct Profile: Sendable {
        let id: UUID
        let name: String
        let voicePrint: [Float]
        let isUser: Bool
    }

    package struct Match: Equatable, Sendable {
        let profileID: UUID
        let name: String
        let similarity: Float
        let isUser: Bool
    }

    /// Below this similarity a speaker is not recognized. Prints of one person recorded with
    /// different microphones are typically above 0.6, different people below 0.4.
    var threshold: Float = 0.55
    /// Speakers with less speech than this have unreliable prints and are not recognized.
    var minimumSpeech: TimeInterval = 3

    package init() {

    }

    /// The recognized profile per speaker index.
    package func match(
        _ voicePrints: [Int: [Float]],
        speech: [Int: TimeInterval],
        profiles: [Profile]
    ) -> [Int: Match] {
        var candidates: [(speaker: Int, profile: Profile, similarity: Float)] = []
        for (speaker, print) in voicePrints where speech[speaker, default: 0] >= minimumSpeech {
            for profile in profiles {
                let similarity = VoicePrint.similarity(print, profile.voicePrint)
                if similarity >= threshold {
                    candidates.append((speaker, profile, similarity))
                }
            }
        }
        var matches: [Int: Match] = [:]
        var usedProfiles = Set<UUID>()
        for candidate in candidates.sorted(by: { $0.similarity > $1.similarity }) {
            guard matches[candidate.speaker] == nil, !usedProfiles.contains(candidate.profile.id) else { continue }
            matches[candidate.speaker] = Match(
                profileID: candidate.profile.id,
                name: candidate.profile.name,
                similarity: candidate.similarity,
                isUser: candidate.profile.isUser
            )
            usedProfiles.insert(candidate.profile.id)
        }
        return matches
    }

    /// The voice print after learning `sample` with `weight` (seconds of speech) in addition to
    /// a print learned from `existingWeight` seconds: the weighted mean, normalized again.
    /// The weight of the existing print is capped, so the profile still adapts to how the
    /// voice sounds in recent recordings.
    package static func merged(_ existing: [Float], existingWeight: TimeInterval, with sample: [Float], weight: TimeInterval) -> [Float] {
        guard existing.count == sample.count else { return sample }
        let old = Float(min(existingWeight, 600))
        let new = Float(max(weight, 1))
        let sum = zip(existing, sample).map { old * $0 + new * $1 }
        return VoicePrint.normalized(sum) ?? sample
    }
}
