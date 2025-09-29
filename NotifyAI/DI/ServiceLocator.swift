//
//  ServiceLocator.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

// App/DI/ServiceLocator.swift
import Foundation

final class ServiceLocator: ObservableObject {
    static let shared = ServiceLocator()

    let audioSession = AudioSessionService()
    let recorder = RecordingService()
    let transcription = TranscriptionService()      // wählt WhisperKit oder Apple Speech
    let diarization = DiarizationService()
    let llm = LLMService()
    let highlight = HighlightService()
    let storage = StorageService()
    let redaction = RedactionService()

    private init() {}
}
