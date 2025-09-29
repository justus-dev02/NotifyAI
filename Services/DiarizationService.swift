//
//  DiarizationService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import AVFoundation

final class DiarizationService {
    // Stub-API: Ersetzt du mit Picovoice Falcon / FluidAudio Call
    func diarize(_ pcmURL: URL) async throws -> [(start: TimeInterval, end: TimeInterval, speakerId: String)] {
        // Platzhalter: echte Implementierung via SDK
        return []
    }
}
