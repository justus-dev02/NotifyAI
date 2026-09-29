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
