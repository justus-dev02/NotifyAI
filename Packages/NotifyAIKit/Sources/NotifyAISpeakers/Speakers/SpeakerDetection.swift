//
//  SpeakerDetection.swift
//  NotifyAISpeakers
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISupport
import SwiftData

/// Speaker detection with the best diarizer available: the neural one once its model is
/// downloaded, otherwise the simple one that needs no download (and cannot recognize voices).
package struct SpeakerDetection: SpeakerDiarizing {
    package let neural: NeuralSpeakerDiarizer
    var simple = SpeakerDiarizer()

    package init(neural: NeuralSpeakerDiarizer, simple: SpeakerDiarizer = SpeakerDiarizer()) {
        self.neural = neural
        self.simple = simple
    }

    /// Whether voices can be recognized and remembered.
    package var recognizesVoices: Bool { neural.isInstalled }

    package func diarize(audioAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Diarization {
        neural.isInstalled
            ? try await neural.diarize(audioAt: url, progress: progress)
            : try await simple.diarize(audioAt: url, progress: progress)
    }
}

/// The voice profiles in the store, as recognition needs them.
@MainActor
package struct VoiceProfiles {
    let store: NoteStore

    package init(store: NoteStore) {
        self.store = store
    }

    /// All profiles, the user's own voice first, then by name.
    package func all() -> [VoiceProfile] {
        store.fetch(FetchDescriptor<VoiceProfile>(sortBy: [SortDescriptor(\.name)]))
            .sorted { $0.isUser && !$1.isUser }
    }

    package func profile(id: UUID) -> VoiceProfile? {
        var descriptor = FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return store.fetch(descriptor).first
    }

    /// The user's own voice, if they recorded or named it.
    package func user() -> VoiceProfile? {
        var descriptor = FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.isUser })
        descriptor.fetchLimit = 1
        return store.fetch(descriptor).first
    }

    /// A profile with this name (case and accents ignored), if one exists.
    package func profile(named name: String) -> VoiceProfile? {
        let key = TextAnalysis.key(name)
        return all().first { TextAnalysis.key($0.name) == key }
    }

    package func recognitionProfiles() -> [VoiceRecognition.Profile] {
        all().map { VoiceRecognition.Profile(id: $0.id, name: $0.name, voicePrint: $0.voicePrint, isUser: $0.isUser) }
    }
}
