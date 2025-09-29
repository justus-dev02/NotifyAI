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

    // Konfigurierbar
    var localeIdentifier: String = "de-DE" {
        didSet { recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) }
    }

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    enum AppleSpeechError: Error {
        case notAuthorized
        case onDeviceNotSupported
        case recognizerUnavailable
    }

    func requestAuthorization() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw AppleSpeechError.notAuthorized }
    }

    func start(handler: @escaping TranscriptionService.TranscriptHandler) throws {
        guard let recognizer, recognizer.isAvailable else { throw AppleSpeechError.recognizerUnavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw AppleSpeechError.onDeviceNotSupported }

        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP])
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        request?.requiresOnDeviceRecognition = true

        task = recognizer.recognitionTask(with: request!) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                // Apple liefert Wort-Timestamps über segments; hier vereinfachen wir:
                handler(text, nil, nil)
            }
            if error != nil {
                // Bei Fehlern Aufnahme stoppen
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
