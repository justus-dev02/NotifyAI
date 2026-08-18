//
//  AppleSpeechBackend.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import AVFoundation
import Speech

final class AppleSpeechBackend: NSObject {
    static let shared = AppleSpeechBackend()

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Current locale identifier (e.g. "de-DE")
    var localeIdentifier: String = "de-DE" {
        didSet {
            guard oldValue != localeIdentifier else { return }
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        }
    }

    /// Whether on-device recognition is available for the current locale
    var isOnDeviceRecognitionAvailable: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    /// Whether the recognizer is currently available
    var isRecognizerAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    /// All locales supported by SFSpeechRecognizer
    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { a, b in
            a.identifier.localizedCompare(b.identifier) == .orderedAscending
        }
    }

    /// Human-readable description for a locale code
    static func localeDescription(for code: String) -> String {
        let locale = Locale(identifier: code)
        if let name = locale.localizedString(forIdentifier: code) {
            return "\(name) (\(code))"
        }
        return code
    }

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    enum AppleSpeechError: Error, LocalizedError {
        case notAuthorized
        case onDeviceNotSupported
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Spracherkennung nicht autorisiert. Bitte in den Einstellungen aktivieren."
            case .onDeviceNotSupported:
                return "On-Device-Erkennung für diese Sprache nicht verfügbar."
            case .recognizerUnavailable:
                return "Spracherkennung ist derzeit nicht verfügbar."
            }
        }
    }

    func requestAuthorization() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw AppleSpeechError.notAuthorized }
    }

    /// Transcribes an audio file using SFSpeechURLRecognitionRequest
    func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }
        try await requestAuthorization()

        let recognitionRequest = SFSpeechURLRecognitionRequest(url: audioURL)
        recognitionRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let error = error {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                } else if let result = result, result.isFinal {
                    if !hasResumed {
                        hasResumed = true
                        let rawSegments = result.bestTranscription.segments
                        if !rawSegments.isEmpty {
                            let mapped = rawSegments.map { seg in
                                TranscriptSegment(
                                    start: seg.timestamp,
                                    end: seg.timestamp + seg.duration,
                                    speakerId: nil,
                                    text: seg.substring
                                )
                            }
                            continuation.resume(returning: mapped)
                        } else {
                            let text = result.bestTranscription.formattedString
                            let asset = AVURLAsset(url: audioURL)
                            let duration = CMTimeGetSeconds(asset.duration)
                            let segment = TranscriptSegment(start: 0, end: duration.isFinite ? duration : 0, speakerId: nil, text: text)
                            continuation.resume(returning: [segment])
                        }
                    }
                }
            }
        }
    }

    func start(handler: @escaping TranscriptionService.TranscriptHandler) throws {
        guard let recognizer, recognizer.isAvailable else { throw AppleSpeechError.recognizerUnavailable }

        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP])
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        request?.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        task = recognizer.recognitionTask(with: request!) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                handler(text, nil, nil)
            }
            if error != nil {
                self.stop()
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        task = nil
        request = nil
    }
}
