//
//  ConsentManager.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation
import AudioToolbox
import AVFoundation

final class ConsentManager {
    static let shared = ConsentManager()

    func playStartBeep() {
        // Kurzer Systemton
        AudioServicesPlaySystemSound(1114) // "begin recording" style
    }

    func makeConsentLog(participants: [String], location: String?, confirmed: Bool) -> ConsentLog {
        return ConsentLog(date: Date(), participants: participants, location: location, confirmed: confirmed)
    }
}
