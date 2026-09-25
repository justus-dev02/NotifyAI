//
//  AppSettings.swift
//  NotifyAI
//

import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
///
/// Settings are read by services through this single object instead of scattered
/// `@AppStorage` properties, so a value has exactly one source of truth.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let engine = "transcription.engine"
        static let language = "transcription.language"
        static let whisperModel = "transcription.whisperModel"
        static let liveTranscription = "transcription.live"
        static let speakerDetection = "processing.speakerDetection"
        static let appLock = "privacy.appLock"
        static let includeInBackup = "privacy.includeInBackup"
        static let onboardingCompleted = "app.onboardingCompleted"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var engine: TranscriptionEngineKind {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    var language: TranscriptionLanguage {
        didSet { defaults.set(language.id, forKey: Key.language) }
    }

    var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.id, forKey: Key.whisperModel) }
    }

    /// Transcribe while recording. When off, the file is transcribed after the recording.
    var liveTranscription: Bool {
        didSet { defaults.set(liveTranscription, forKey: Key.liveTranscription) }
    }

    /// Experimental speaker detection after transcription.
    var speakerDetection: Bool {
        didSet { defaults.set(speakerDetection, forKey: Key.speakerDetection) }
    }

    var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Key.appLock) }
    }

    /// Whether recordings and notes are part of iCloud / computer backups. Off by default:
    /// data stays in the app until the user decides otherwise.
    var includeInBackup: Bool {
        didSet { defaults.set(includeInBackup, forKey: Key.includeInBackup) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboardingCompleted) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = defaults.string(forKey: Key.engine).flatMap(TranscriptionEngineKind.init(rawValue:)) ?? .appleSpeech
        language = defaults.string(forKey: Key.language).map(TranscriptionLanguage.init(id:)) ?? Self.defaultLanguage
        whisperModel = defaults.string(forKey: Key.whisperModel).flatMap(WhisperModel.withID) ?? .recommended
        liveTranscription = defaults.object(forKey: Key.liveTranscription) as? Bool ?? true
        speakerDetection = defaults.bool(forKey: Key.speakerDetection)
        appLockEnabled = defaults.bool(forKey: Key.appLock)
        includeInBackup = defaults.bool(forKey: Key.includeInBackup)
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboardingCompleted)
    }

    var transcriptionOptions: TranscriptionOptions {
        TranscriptionOptions(language: language, whisperModel: whisperModel)
    }

    /// The system language if it is supported, German otherwise.
    private static var defaultLanguage: TranscriptionLanguage {
        let preferred = Locale.current.language
        return TranscriptionLanguage.all.first {
            $0.locale.language.languageCode == preferred.languageCode && $0.locale.region == preferred.region
        } ?? TranscriptionLanguage.all.first {
            $0.locale.language.languageCode == preferred.languageCode
        } ?? .german
    }
}
