//
//  AnalysisSettings.swift
//  NotifyAIServices
//

import Foundation
import Observation

/// What happens after (and during) a recording: speakers and summaries.
@MainActor
@Observable
public final class AnalysisSettings {
    private enum Key {
        static let speakerDetection = "processing.speakerDetection"
        static let speakersFromAudioSource = "processing.speakersFromAudioSource"
        static let summarizeWhileRecording = "processing.summarizeWhileRecording"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Experimental voice-based speaker detection after transcription.
    public var speakerDetection: Bool {
        didSet { defaults.set(speakerDetection, forKey: Key.speakerDetection) }
    }

    /// Labels "Mikrofon + Systemton" recordings as "Ich" (microphone) and "Andere" (system audio).
    public var speakersFromAudioSource: Bool {
        didSet { defaults.set(speakersFromAudioSource, forKey: Key.speakersFromAudioSource) }
    }

    /// Summarizes finished chapters of long recordings while still recording, so the summary
    /// is ready seconds after stopping. Uses the Neural Engine during the recording.
    public var summarizeWhileRecording: Bool {
        didSet { defaults.set(summarizeWhileRecording, forKey: Key.summarizeWhileRecording) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        speakerDetection = defaults.bool(forKey: Key.speakerDetection)
        speakersFromAudioSource = defaults.object(forKey: Key.speakersFromAudioSource) as? Bool ?? true
        summarizeWhileRecording = defaults.object(forKey: Key.summarizeWhileRecording) as? Bool ?? Self.summarizesWhileRecordingByDefault
    }

    /// On by default on the Mac and iPad. On the iPhone the Neural Engine is shared with live
    /// transcription and the battery is smaller, so it is opt-in there.
    private static var summarizesWhileRecordingByDefault: Bool {
        DeviceProfile.current != .phone
    }
}
