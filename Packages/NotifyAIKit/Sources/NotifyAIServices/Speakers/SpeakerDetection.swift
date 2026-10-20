//
//  SpeakerDetection.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import SwiftData

/// Speaker detection with the best diarizer available: the neural one once its model is
/// downloaded, otherwise the simple one that needs no download (and cannot recognize voices).
struct SpeakerDetection: SpeakerDiarizing {
    let neural: NeuralSpeakerDiarizer
    var simple = SpeakerDiarizer()

    /// Whether voices can be recognized and remembered.
    var recognizesVoices: Bool { neural.isInstalled }

    func diarize(audioAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        neural.isInstalled
            ? try await neural.diarize(audioAt: url, progress: progress)
            : try await simple.diarize(audioAt: url, progress: progress)
    }
}

/// The voice profiles in the store, as recognition needs them.
@MainActor
struct VoiceProfiles {
    let store: NoteStore

    /// All profiles, the user's own voice first, then by name.
    func all() -> [VoiceProfile] {
        store.fetch(FetchDescriptor<VoiceProfile>(sortBy: [SortDescriptor(\.name)]))
            .sorted { $0.isUser && !$1.isUser }
    }

    func profile(id: UUID) -> VoiceProfile? {
        var descriptor = FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return store.fetch(descriptor).first
    }

    /// The user's own voice, if they recorded or named it.
    func user() -> VoiceProfile? {
        var descriptor = FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.isUser })
        descriptor.fetchLimit = 1
        return store.fetch(descriptor).first
    }

    /// A profile with this name (case and accents ignored), if one exists.
    func profile(named name: String) -> VoiceProfile? {
        let key = TextAnalysis.key(name)
        return all().first { TextAnalysis.key($0.name) == key }
    }

    func recognitionProfiles() -> [VoiceRecognition.Profile] {
        all().map { VoiceRecognition.Profile(id: $0.id, name: $0.name, voicePrint: $0.voicePrint, isUser: $0.isUser) }
    }
}
