//
//  SpeakerStep.swift
//  NotifyAIProcessing
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAISettings
import NotifyAISpeakers
import NotifyAISupport
import OSLog

/// Step 2: labels transcript segments with speakers.
///
/// Combines the audio source of a "Mikrofon + Systemton" recording ("Ich" / the other side),
/// speaker detection (who of the others speaks) and recognized voices (names the user gave
/// before); see `SpeakerAttribution`. Corrections of the user (renamed speakers, edited
/// text) are never overwritten: the step only runs again when the note is transcribed anew.
@MainActor
struct SpeakerStep {
    let settings: AnalysisSettings
    let diarizer: any SpeakerDiarizing
    let profiles: VoiceProfiles
    var recognition = VoiceRecognition()

    func needsToRun(for note: Note, options: ProcessingOptions) -> Bool {
        note.kind.hasAudio
            && (options.forceTranscription || (note.summary == nil && note.transcriptEditedAt == nil))
    }

    func run(_ note: Note, context: ProcessingContext) async throws {
        let activity = settings.speakersFromAudioSource ? note.sourceActivity : nil
        guard activity != nil || settings.speakerDetection else { return }
        context.setStage(.identifyingSpeakers, settings.speakerDetection ? 0 : nil)

        var evidence = SpeakerAttribution.Evidence(
            activity: activity,
            othersLabel: SourceSpeakerAttribution.othersLabel(participants: note.participants)
        )
        if settings.speakerDetection, let audioURL = context.store.audioURL(for: note) {
            do {
                let diarization = try await diarizer.diarize(audioAt: audioURL, progress: context.progress)
                evidence.diarization = diarization
                evidence.matches = recognition.match(
                    diarization.voicePrints,
                    speech: diarization.speechPerVoice,
                    profiles: profiles.recognitionProfiles()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Without detection the note still gets its transcript, summary and the
                // audio source's labels; detection can be repeated by transcribing again.
                Logger.processing.error("Speaker detection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try Task.checkCancellation()

        let result = SpeakerAttribution.attribute(note.decodedTranscript(), evidence: evidence)
        guard !result.speakers.isEmpty else { return }
        note.speakers = result.speakers
        try await context.saveTranscript(result.segments, engine: note.transcriptionEngine, to: note)
    }
}
