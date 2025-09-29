//
//  ServiceLocator.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

// App/DI/ServiceLocator.swift
import Foundation
import Combine

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
    let pipeline: PipelineManager

    private init() {
        self.pipeline = PipelineManager(storage: storage, diarizer: diarization, llm: llm, highlight: highlight)
    }
}
