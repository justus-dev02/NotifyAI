//
//  AudioSessionService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import AVFoundation

final class AudioSessionService {
    func configureForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
