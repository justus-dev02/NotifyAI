//
//  AudioSource.swift
//  NotifyAICore
//

import Foundation

/// What a recording captures.
///
/// System audio (the sound other apps play, e.g. the participants of a Zoom, Teams or
/// Discord call) can only be recorded on the Mac, through Core Audio process taps.
/// User-facing names are defined in `NotifyAIServices` (`DomainNames.swift`).
public enum RecordingAudioSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The microphone only: conversations in the room.
    case microphone
    /// Microphone and system audio mixed: online meetings, own voice included.
    case microphoneAndSystemAudio
    /// System audio only: webinars, videos, podcasts.
    case systemAudio

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .microphone: "mic"
        case .microphoneAndSystemAudio: "person.2.wave.2"
        case .systemAudio: "speaker.wave.2"
        }
    }

    public var usesMicrophone: Bool { self != .systemAudio }
    public var usesSystemAudio: Bool { self != .microphone }

    /// Sources this platform can record. iOS does not allow capturing other apps' audio.
    public static var available: [Self] {
        #if os(macOS)
        allCases
        #else
        [.microphone]
        #endif
    }
}

/// Which apps' audio a system audio recording captures.
public enum SystemAudioTarget: Codable, Hashable, Sendable {
    /// Everything the Mac plays, except NotifyAI itself.
    case allApps
    /// One app including its helper processes (browsers and Electron apps play audio from helpers).
    case app(bundleID: String, name: String)

    public var bundleID: String? {
        switch self {
        case .allApps: nil
        case .app(let bundleID, _): bundleID
        }
    }
}

/// The available on-device speech recognizers.
public enum TranscriptionEngineKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Apple's `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26, macOS 26).
    case appleSpeech
    /// OpenAI Whisper running on the Neural Engine via WhisperKit.
    case whisper

    public var id: String { rawValue }

    /// Product names; they are not translated.
    public var displayName: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .whisper: "Whisper"
        }
    }
}
