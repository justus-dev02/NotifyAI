//
//  SpeechTranscriber.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Refactored by Gemini on 24.10.25.
//
/*
import Foundation
import Speech
import AVFoundation
import Combine

// MARK: - Transcript Data Models

/// Ein einzelnes Segment des transkribierten Textes.
/// HINWEIS: Diese Struktur fehlte in deinem ursprünglichen Code.
struct TranscriptSegment: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speakerId: String? // Für zukünftige Sprecher-Erkennung
    let text: String
}

/// Das finale Ergebnis einer Transkription (aus einer Datei oder einer kompletten Live-Sitzung).
struct TranscriptResult {
    let text: String
    let confidence: Float
    let segments: [TranscriptSegment]
    let language: String
    let timestamp: Date
    
    init(text: String, confidence: Float, segments: [TranscriptSegment], language: String) {
        self.text = text
        self.confidence = confidence
        self.segments = segments
        self.language = language
        self.timestamp = Date()
    }
}

/// Ein Update-Paket, das während einer Live-Transkription gesendet wird.
struct TranscriptionUpdate {
    let text: String
    let confidence: Float
    let isFinal: Bool
}

// MARK: - Transcription Errors

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognitionRequestFailed
    case audioEngineError
    case fileNotFound
    case unsupportedFormat
    case unsupportedLocale
    case taskCancelled
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Spracherkennung nicht autorisiert. Bitte in den Einstellungen aktivieren."
        case .recognitionRequestFailed:
            return "Erstellung der Erkennungsanfrage fehlgeschlagen."
        case .audioEngineError:
            return "Fehler bei der Audio-Engine."
        case .fileNotFound:
            return "Audiodatei nicht gefunden."
        case .unsupportedFormat:
            return "Nicht unterstütztes Audioformat."
        case .unsupportedLocale:
            return "Die eingestellte Sprache/Region wird nicht unterstützt."
        case .taskCancelled:
            return "Die Transkription wurde abgebrochen."
        }
    }
}

// MARK: - Speech Transcriber Service

/**
 Ein globaler Dienst (Singleton), der die Kernlogik der SFSpeech-API kapselt.
 Diese Klasse ist als `@MainActor` markiert, da SFSpeech-Operationen auf dem Main Thread erfolgen sollten.
 Sie ist ein `ObservableObject`, damit die UI auf globale Zustände wie `isProcessing` (für Dateien) reagieren kann.
 */
@MainActor
class SpeechTranscriber: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    
    static let shared = SpeechTranscriber()
    
    // MARK: - Published Properties
    /// Zeigt an, ob eine Datei-Transkription im Gange ist (für einen globalen Ladeindikator).
    @Published var isProcessing = false
    /// Zeigt an, ob die Berechtigung zur Spracherkennung erteilt wurde.
    @Published var isAuthorized = false
    /// Die zuletzt aufgetretene Fehlermeldung.
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    private var speechRecognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var audioSession = AVAudioSession.sharedInstance()

    /// Der aktuelle Recognition Task für Live-Audio.
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Die "Continuation" für den AsyncStream, um Live-Updates zu senden.
    private var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    // MARK: - Initialization
    private override init() {
        // Sicherer Initialisierer.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")) else {
            // Dies ist ein schwerwiegender Fehler. In einer echten App würden wir einen Fehler auslösen.
            // Für ein Singleton ist fatalError hier fast schon angebracht, oder wir setzen einen Fehlerstatus.
            fatalError("Locale 'de-DE' wird nicht unterstützt.")
        }
        self.speechRecognizer = recognizer
        
        super.init()
        self.speechRecognizer.delegate = self
        
        // Berechtigung anfordern.
        requestAuthorization()
    }
    
    // MARK: - Authorization
    private func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.isAuthorized = true
                default:
                    self?.isAuthorized = false
                }
            }
        }
    }
    
    // MARK: - Public API: Real-time Transcription
    
    /// Startet eine Echtzeit-Transkription und gibt einen Stream von Updates zurück.
    /// Der Aufrufer kann diesen Stream mit `for try await update in stream` konsumieren.
    func startRealTimeTranscription() async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        guard isAuthorized else {
            throw TranscriptionError.notAuthorized
        }
        
        // Vorherige Tasks bereinigen
        stopRealTimeTranscription()
        
        // Audio-Session konfigurieren
        try configureAudioSession()
        
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Install Tap für das Mikrofon
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        // Erstellt den AsyncStream. Die Closure wird sofort ausgeführt.
        return AsyncThrowingStream { continuation in
            self.streamContinuation = continuation
            
            // Definiert, was passiert, wenn der Stream beendet wird (z.B. durch Task-Abbruch)
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stopRealTimeTranscription()
            }
            
            // Startet den SFSpeech Recognition Task
            self.recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self = self else { return }

                if let result = result {
                    // Erstellt ein Update-Paket
                    let segments = result.bestTranscription.segments
                    let avgConfidence = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + $1.confidence } / Float(segments.count)
                    
                    let update = TranscriptionUpdate(
                        text: result.bestTranscription.formattedString,
                        confidence: avgConfidence,
                        isFinal: result.isFinal
                    )
                    
                    // Sendet das Update an den Stream
                    self.streamContinuation?.yield(update)
                    
                    if result.isFinal {
                        // Wenn SFSpeech "final" sagt, beenden wir den Stream.
                        self.streamContinuation?.finish()
                        self.stopRealTimeTranscription()
                    }
                } else if let error = error {
                    // Sendet einen Fehler an den Stream
                    self.streamContinuation?.finish(throwing: error)
                    self.stopRealTimeTranscription()
                }
            }
        }
    }
    
    /// Stoppt die Echtzeit-Transkription und bereinigt die Ressourcen.
    func stopRealTimeTranscription() {
        // Stream beenden, falls er noch läuft
        streamContinuation?.finish()
        streamContinuation = nil
        
        // Task beenden
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Audio-Engine stoppen
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // Request beenden
        // recognitionRequest?.endAudio() // `recognitionRequest` ist nicht mehr als Property gespeichert
        
        try? audioSession.setActive(false)
    }
    
    // MARK: - Public API: File-based Transcription
    
    /// Transkribiert eine einzelne Audiodatei asynchron.
    func transcribeAudioFile(url: URL) async throws -> TranscriptResult {
        guard isAuthorized else {
            throw TranscriptionError.notAuthorized
        }
        
        await MainActor.run {
            self.isProcessing = true
            self.errorMessage = nil
        }
        
        defer {
            Task { @MainActor in
                self.isProcessing = false
            }
        }
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        
        // Wir verpacken die alte Callback-API in eine moderne async-Funktion
        return try await withCheckedThrowingContinuation { continuation in
            let task = speechRecognizer.recognitionTask(with: request) { [weak self] (result, error) in
                guard let self = self else {
                    continuation.resume(throwing: TranscriptionError.taskCancelled)
                    return
                }

                if let error = error {
                    Task { @MainActor in
                        self.errorMessage = error.localizedDescription
                    }
                    continuation.resume(throwing: error)
                } else if let result = result, result.isFinal {
                    // Erfolg
                    let transcriptResult = self.createResult(from: result.bestTranscription)
                    continuation.resume(returning: transcriptResult)
                }
                // Wenn nicht final, warten wir weiter.
            }
            
            // Ermöglicht das Abbrechen des Tasks (z.B. wenn die View verschwindet)
            Task {
                if await Task.isCancelled {
                    task.cancel()
                    continuation.resume(throwing: TranscriptionError.taskCancelled)
                }
            }
        }
    }
    
    // MARK: - Public API: Batch Processing
    
    /// Transkribiert mehrere Dateien parallel für maximale Geschwindigkeit.
    /// Die Reihenfolge der Ergebnisse ist nicht garantiert.
    func transcribeMultipleFiles(urls: [URL]) async throws -> [TranscriptResult] {
        guard isAuthorized else {
            throw TranscriptionError.notAuthorized
        }
        
        // Verwende eine TaskGroup, um alle Transkriptionen parallel zu starten
        return try await withThrowingTaskGroup(of: TranscriptResult.self) { group in
            var results: [TranscriptResult] = []
            
            for url in urls {
                group.addTask {
                    // Jede Datei wird in einem eigenen Child-Task transkribiert
                    return try await self.transcribeAudioFile(url: url)
                }
            }
            
            // Sammle die Ergebnisse, sobald sie eintreffen
            for try await result in group {
                results.append(result)
            }
            
            return results
        }
    }
    
    // MARK: - Private Methods
    
    private func configureAudioSession() throws {
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    private func createResult(from transcription: SFTranscription) -> TranscriptResult {
        let segments = transcription.segments.map { segment in
            TranscriptSegment(
                start: segment.timestamp,
                end: segment.timestamp + segment.duration,
                speakerId: nil, // Nicht von SFSpeech unterstützt
                text: segment.substring
            )
        }
        
        return TranscriptResult(
            text: transcription.formattedString,
            confidence: transcription.averageConfidence,
            segments: segments,
            language: speechRecognizer.locale.identifier
        )
    }
}


// MARK: - Real-time Transcription View Model

/**
 Dieses ViewModel verwaltet den Zustand für einen *einzigen* Transkriptions-Screen.
 Es startet einen Task, um den Live-Stream vom `SpeechTranscriber` zu konsumieren
 und aktualisiert seine eigenen `@Published`-Properties für die View.
 */
class RealTimeTranscriptionViewModel: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentText = ""
    @Published var finalText = "" // Der letzte finale Text
    @Published var confidence: Float = 0.0
    @Published var errorMessage: String?
    
    private let transcriber = SpeechTranscriber.shared
    private var transcriptionTask: Task<Void, Never>?
    
    @MainActor
    func startTranscription() {
        // Breche einen laufenden Task ab, falls vorhanden
        stopTranscription()
        
        isTranscribing = true
        errorMessage = nil
        currentText = ""
        finalText = ""
        
        transcriptionTask = Task {
            do {
                let stream = try await transcriber.startRealTimeTranscription()
                
                // Konsumiere den Stream von Updates
                for try await update in stream {
                    // Stelle sicher, dass wir noch auf dem MainActor sind (sollte durch Stream gewährleistet sein)
                    await MainActor.run {
                        self.currentText = update.text
                        self.confidence = update.confidence
                        if update.isFinal {
                            self.finalText = update.text
                        }
                    }
                }
            } catch {
                if error is CancellationError || (error as? TranscriptionError) == .taskCancelled {
                    // Normaler Abbruch, kein Fehler
                } else {
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
            
            // Aufräumen, wenn der Stream endet (normal oder durch Fehler)
            await MainActor.run {
                self.isTranscribing = false
            }
        }
    }
    
    @MainActor
    func stopTranscription() {
        // Das Abbrechen des Tasks löst `continuation.onTermination`
        // im `SpeechTranscriber` aus, was die Audio-Engine stoppt.
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
    }
    
    @MainActor
    func clearText() {
        currentText = ""
        finalText = ""
    }
}
*/
