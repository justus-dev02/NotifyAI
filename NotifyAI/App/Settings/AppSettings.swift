//
//  AppSettings.swift
//  NotifyAI
//

import Foundation
import Observation

/// All user preferences, grouped by topic and persisted in `UserDefaults`.
///
/// Each group is its own observable object with its own keys, so a view or service depends
/// only on the preferences it uses (the processing never sees privacy settings, the
/// settings screen for privacy never re-renders when the language changes). There is still
/// exactly one source of truth per value.
@MainActor
@Observable
final class AppSettings {
    let transcription: TranscriptionSettings
    let recording: RecordingSettings
    let analysis: AnalysisSettings
    let privacy: PrivacySettings
    let general: GeneralSettings

    init(defaults: UserDefaults = .standard) {
        transcription = TranscriptionSettings(defaults: defaults)
        recording = RecordingSettings(defaults: defaults)
        analysis = AnalysisSettings(defaults: defaults)
        privacy = PrivacySettings(defaults: defaults)
        general = GeneralSettings(defaults: defaults)
    }
}

extension AppSettings {
    /// The technical preferences for a diagnosis report. The target app of a system audio
    /// recording is left out; it says something about the user's work.
    var diagnosticsSummary: [String] {
        [
            String(localized: "Spracherkennung: \(transcription.engine.rawValue), Sprache: \(transcription.language.id), Whisper-Modell: \(transcription.whisperModel.id)"),
            String(localized: "Live-Transkript: \(String(describing: transcription.liveTranscription))"),
            String(localized: "Audioquelle: \(recording.audioSource.rawValue)"),
            String(localized: "Sprechererkennung: \(String(describing: analysis.speakerDetection)), Ich/Andere aus Quelle: \(String(describing: analysis.speakersFromAudioSource)), Kapitel während der Aufnahme: \(String(describing: analysis.summarizeWhileRecording))"),
            String(localized: "App-Sperre: \(String(describing: privacy.appLockEnabled)), Backup: \(String(describing: privacy.includeInBackup))"),
            String(localized: "Darstellung: \(general.appPresence.rawValue)"),
        ]
    }
}
