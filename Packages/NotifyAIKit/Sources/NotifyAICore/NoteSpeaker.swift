//
//  NoteSpeaker.swift
//  NotifyAICore
//

import Foundation

/// A speaker of a note's transcript.
///
/// Segments name their speaker by `label` (`TranscriptSegment.speaker`); the speaker keeps
/// what the label alone cannot: the voice print for recognizing the voice in other
/// recordings, and whether the name was detected, recognized or given by the user.
public struct NoteSpeaker: Codable, Hashable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Found by speaker detection, numbered ("Sprecher 2").
        case detected
        /// Recognized automatically as a voice profile.
        case recognized
        /// Named by the user.
        case named
        /// From the audio source of a "Mikrofon + Systemton" recording ("Ich", "Andere").
        case audioSource
    }

    public var id: UUID
    /// The name in the transcript.
    public var label: String
    public var origin: Origin
    /// L2-normalized voice print; `nil` without neural speaker detection.
    public var voicePrint: [Float]?
    /// Seconds this speaker talks in the transcript.
    public var speechDuration: TimeInterval
    /// The voice profile the speaker was recognized as or named after.
    public var profileID: UUID?
    /// Cosine similarity of the voice print to the recognized profile.
    public var similarity: Float?

    public init(
        id: UUID = UUID(),
        label: String,
        origin: Origin,
        voicePrint: [Float]? = nil,
        speechDuration: TimeInterval = 0,
        profileID: UUID? = nil,
        similarity: Float? = nil
    ) {
        self.id = id
        self.label = label
        self.origin = origin
        self.voicePrint = voicePrint
        self.speechDuration = speechDuration
        self.profileID = profileID
        self.similarity = similarity
    }
}
