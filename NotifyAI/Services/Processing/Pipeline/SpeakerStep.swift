//
//  SpeakerStep.swift
//  NotifyAI
//

import Foundation

/// Step 2: labels transcript segments with speakers.
///
/// A microphone + system audio recording knows who spoke from which source ("Ich" /
/// "Andere"), which is far more reliable than the experimental voice-based detection, so
/// it takes precedence.
@MainActor
struct SpeakerStep {
    let settings: AnalysisSettings
    let diarizer: SpeakerDiarizer

    func needsToRun(for note: Note, options: ProcessingOptions) -> Bool {
        note.kind.hasAudio && (options.forceTranscription || note.summary == nil)
    }

    func run(_ note: Note, context: ProcessingContext) async throws {
        if settings.speakersFromAudioSource, let activity = note.sourceActivity {
            context.setStage(.identifyingSpeakers, nil)
            let segments = SourceSpeakerAttribution.assign(
                activity,
                to: note.decodedTranscript(),
                othersLabel: SourceSpeakerAttribution.othersLabel(participants: note.participants)
            )
            try await context.saveTranscript(segments, engine: note.transcriptionEngine, to: note)
        } else if settings.speakerDetection, let audioURL = context.store.audioURL(for: note) {
            context.setStage(.identifyingSpeakers, 0)
            let turns = try await diarizer.turns(forAudioAt: audioURL, progress: context.progress)
            try Task.checkCancellation()
            guard !turns.isEmpty else { return }
            let segments = SpeakerDiarizer.assignSpeakers(turns, to: note.decodedTranscript())
            try await context.saveTranscript(segments, engine: note.transcriptionEngine, to: note)
        }
    }
}
