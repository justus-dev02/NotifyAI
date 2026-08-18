//
//  ServiceLocator.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import Combine

final class ServiceLocator: ObservableObject {
    static let shared = ServiceLocator()

    let audioSession: AudioSessionService
    let recorder: RecordingService
    let transcription: TranscriptionService
    let diarization: DiarizationService
    let llm: LLMService
    let highlight: HighlightService
    let storage: StorageService
    let redaction: RedactionService
    let pipeline: PipelineManager

    private init() {
        let audioSession = AudioSessionService()
        let recorder = RecordingService()
        let transcription = TranscriptionService()
        let diarization = DiarizationService()
        let llm = LLMService()
        let highlight = HighlightService(llm: llm)
        let storage = StorageService()
        let redaction = RedactionService()
        let pipeline = PipelineManager(
            storage: storage,
            diarizer: diarization,
            llm: llm,
            highlight: highlight,
            transcription: transcription
        )

        self.audioSession = audioSession
        self.recorder = recorder
        self.transcription = transcription
        self.diarization = diarization
        self.llm = llm
        self.highlight = highlight
        self.storage = storage
        self.redaction = redaction
        self.pipeline = pipeline
    }
}
