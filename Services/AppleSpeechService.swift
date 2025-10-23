//
//  AppleSpeechService.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import Foundation
import Speech
import AVFoundation

class AppleSpeechService: NSObject, ObservableObject {
    static let shared = AppleSpeechService()
    
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var recognizedText = ""
    @Published var isFinal = false
    
    private let speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var onTextUpdate: ((String, Bool) -> Void)?
    
    override init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")) ?? SFSpeechRecognizer()!
        super.init()
        requestAuthorization()
    }
    
    // MARK: - Authorization
    
    private func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.isAuthorized = true
                case .denied, .restricted, .notDetermined:
                    self?.isAuthorized = false
                @unknown default:
                    self?.isAuthorized = false
                }
            }
        }
    }
    
    // MARK: - Recording Control
    
    func startRecording(onTextUpdate: @escaping (String, Bool) -> Void) throws {
        guard isAuthorized else {
            throw SpeechError.notAuthorized
        }
        
        guard !isRecording else { return }
        
        self.onTextUpdate = onTextUpdate
        
        // Cancel any previous recognition task
        if let recognitionTask = recognitionTask {
            recognitionTask.cancel()
            self.recognitionTask = nil
        }
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw SpeechError.recognitionRequestFailed
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // Configure audio engine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    self?.recognizedText = result.bestTranscription.formattedString
                    self?.isFinal = result.isFinal
                    self?.onTextUpdate?(result.bestTranscription.formattedString, result.isFinal)
                }
                
                if let error = error {
                    print("Speech recognition error: \(error)")
                    self?.stopRecording()
                }
            }
        }
        
        isRecording = true
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        isRecording = false
    }
    
    func pauseRecording() {
        audioEngine.pause()
    }
    
    func resumeRecording() {
        try? audioEngine.start()
    }
    
    // MARK: - File-based Recognition
    
    func recognizeFile(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard isAuthorized else {
            completion(.failure(SpeechError.notAuthorized))
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        
        speechRecognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result = result, result.isFinal {
                    completion(.success(result.bestTranscription.formattedString))
                } else if let error = error {
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Language Support
    
    func setLanguage(_ locale: Locale) {
        // Note: SFSpeechRecognizer doesn't support changing locale after initialization
        // This would require creating a new instance
    }
    
    func getSupportedLocales() -> [Locale] {
        return Array(SFSpeechRecognizer.supportedLocales())
    }
}

// MARK: - Error Types

enum SpeechError: LocalizedError {
    case notAuthorized
    case recognitionRequestFailed
    case audioEngineError
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized"
        case .recognitionRequestFailed:
            return "Failed to create recognition request"
        case .audioEngineError:
            return "Audio engine error"
        }
    }
}

// MARK: - Real-time Transcription Service

class RealTimeTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentText = ""
    @Published var finalText = ""
    
    private let speechService = AppleSpeechService.shared
    private var accumulatedText = ""
    
    func startTranscription() throws {
        try speechService.startRecording { [weak self] text, isFinal in
            DispatchQueue.main.async {
                self?.currentText = text
                
                if isFinal {
                    self?.finalText = text
                    self?.accumulatedText += text + " "
                }
            }
        }
        
        isTranscribing = true
    }
    
    func stopTranscription() {
        speechService.stopRecording()
        isTranscribing = false
    }
    
    func pauseTranscription() {
        speechService.pauseRecording()
    }
    
    func resumeTranscription() {
        speechService.resumeRecording()
    }
    
    func getAccumulatedText() -> String {
        return accumulatedText
    }
    
    func clearText() {
        currentText = ""
        finalText = ""
        accumulatedText = ""
    }
}

