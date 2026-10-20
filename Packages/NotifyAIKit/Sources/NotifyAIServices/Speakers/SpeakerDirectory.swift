//
//  SpeakerDirectory.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import Observation
import OSLog

/// Errors of naming speakers, reported to the user.
public enum SpeakerNamingError: LocalizedError {
    case emptyName
    case speakerNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Bitte gib einen Namen ein.", bundle: .module)
        case .speakerNotFound: String(localized: "Dieser Sprecher kommt im Transkript nicht mehr vor.", bundle: .module)
        }
    }
}

/// The user's corrections of who spoke, and the voices they remember.
///
/// Naming a speaker renames it everywhere in the note. With "Stimme merken" its voice print
/// is learned into the voice profile of that name (created if needed), so the voice gets its
/// name automatically in later recordings (`VoiceRecognition`). Naming never renames or
/// overwrites another profile: if a voice was recognized wrongly, the new name gets its own
/// profile and the wrong one stays as it was. Every change marks the transcript as edited,
/// so speaker detection never overwrites it.
@MainActor
@Observable
public final class SpeakerDirectory {
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let profiles: VoiceProfiles
    @ObservationIgnored private let detection: SpeakerDetection
    @ObservationIgnored private let writer: TranscriptWriter

    init(store: NoteStore, detection: SpeakerDetection) {
        self.store = store
        self.detection = detection
        profiles = VoiceProfiles(store: store)
        writer = TranscriptWriter(store: store)
    }

    /// Whether voices can be remembered: the neural speaker model is installed.
    public var remembersVoices: Bool { detection.recognizesVoices }

    /// The label of the user's own voice ("Ich").
    nonisolated public static var userLabel: String { SourceSpeakerAttribution.userLabel }
    public var userLabel: String { Self.userLabel }

    /// Names that fit as speakers: remembered voices and the note's participants.
    public func suggestedNames(for note: Note) -> [String] {
        var seen = Set<String>()
        return (profiles.all().filter { !$0.isUser }.map(\.name) + note.participants)
            .filter { seen.insert(TextAnalysis.key($0)).inserted }
    }

    // MARK: - Naming speakers in a note

    /// Renames a speaker everywhere in the note. Renaming to an existing speaker merges both.
    /// - Parameter remembersVoice: Learns the voice under the new name for later recordings.
    public func rename(_ label: String, to name: String, in note: Note, remembersVoice: Bool) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SpeakerNamingError.emptyName }
        let isUser = TextAnalysis.key(name) == TextAnalysis.key(userLabel)
        let target = isUser ? userLabel : name
        var speakers = note.speakers
        guard let index = speakers.firstIndex(where: { $0.label == label }) ?? Self.implicitSpeaker(label, in: note, appendingTo: &speakers) else {
            throw SpeakerNamingError.speakerNotFound
        }
        var speaker = speakers[index]
        if remembersVoice, let voicePrint = speaker.voicePrint {
            let learned = speaker.origin == .named ? speaker.profileID : nil
            let profile = try remember(voicePrint, speech: speaker.speechDuration, as: target, isUser: isUser, alreadyLearned: learned)
            speaker.profileID = profile.id
        } else if speaker.label != target {
            speaker.profileID = nil
        }
        speaker.label = target
        speaker.origin = .named
        speaker.similarity = nil
        speakers[index] = speaker
        // Merging into a speaker of that name: the renamed one takes its place.
        speakers.removeAll { $0.label == target && $0.id != speaker.id }

        let segments = note.decodedTranscript().map { segment in
            var segment = segment
            if segment.speaker == label { segment.speaker = target }
            return segment
        }
        try await writer.save(segments, speakers: speakers, to: note, edited: true)
    }

    /// Confirms a recognized name and learns the voice once more.
    public func confirm(_ label: String, in note: Note) async throws {
        try await rename(label, to: label, in: note, remembersVoice: true)
    }

    /// Gives one segment another speaker, or none.
    public func assign(segmentID: TranscriptSegment.ID, to name: String?, in note: Note) async throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty { throw SpeakerNamingError.emptyName }
        let label = name.map { TextAnalysis.key($0) == TextAnalysis.key(userLabel) ? userLabel : $0 }
        var segments = note.decodedTranscript()
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { throw SpeakerNamingError.speakerNotFound }
        segments[index].speaker = label
        var speakers = note.speakers
        if let label, !speakers.contains(where: { $0.label == label }) {
            speakers.append(NoteSpeaker(label: label, origin: .named))
        }
        try await writer.save(segments, speakers: speakers, to: note, edited: true)
    }

    // MARK: - Voice profiles

    /// Renames a remembered voice. Notes keep the names they have.
    public func rename(_ profile: VoiceProfile, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SpeakerNamingError.emptyName }
        profile.name = name
        profile.updatedAt = .now
        try store.save()
    }

    /// Forgets a voice: it is no longer recognized. Notes keep the names they have.
    public func delete(_ profile: VoiceProfile) throws {
        let id = profile.id
        try store.deleteModel(profile)
        Logger.processing.info("Deleted voice profile \(id, privacy: .public)")
    }

    // MARK: - Private

    /// Learns `voicePrint` into the profile named `name`, creating it if needed.
    /// - Parameter alreadyLearned: The profile this speaker was learned into before; it is not
    ///   learned twice from the same recording.
    private func remember(_ voicePrint: [Float], speech: TimeInterval, as name: String, isUser: Bool, alreadyLearned: UUID?) throws -> VoiceProfile {
        let existing = isUser ? profiles.user() : profiles.profile(named: name)
        if let existing {
            guard existing.id != alreadyLearned else { return existing }
            existing.setVoicePrint(VoiceRecognition.merged(existing.voicePrint, existingWeight: existing.speechDuration, with: voicePrint, weight: speech))
            existing.sampleCount += 1
            existing.speechDuration += speech
            existing.updatedAt = .now
            try store.save()
            return existing
        }
        let profile = VoiceProfile(
            name: name,
            isUser: isUser,
            voicePrintData: VoiceProfile.encode(voicePrint),
            speechDuration: speech
        )
        try store.insertModel(profile)
        return profile
    }

    /// Transcripts from before speakers were stored have labels but no speaker entries.
    private static func implicitSpeaker(_ label: String, in note: Note, appendingTo speakers: inout [NoteSpeaker]) -> Int? {
        guard note.decodedTranscript().contains(where: { $0.speaker == label }) else { return nil }
        speakers.append(NoteSpeaker(label: label, origin: .detected))
        return speakers.count - 1
    }
}
