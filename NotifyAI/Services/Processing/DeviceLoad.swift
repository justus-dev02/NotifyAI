//
//  DeviceLoad.swift
//  NotifyAI
//

import Foundation
import OSLog

/// Keeps long work from overheating the device.
///
/// Processing a four-hour recording runs the Neural Engine and CPU for minutes. When the
/// device reports a serious thermal state, work pauses between steps (chapters, audio
/// blocks) until it has cooled down, instead of making the system throttle everything else.
/// Optional background work (summarizing while recording) is skipped entirely under load
/// or in Low Power Mode.
enum DeviceLoad {
    /// Whether optional work should be skipped right now.
    static var isConstrained: Bool {
        let info = ProcessInfo.processInfo
        return info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue || info.isLowPowerModeEnabled
    }

    /// Waits while the device is hot, checking every `interval`, but never longer than
    /// `maximumWait`: the work has to finish eventually.
    static func waitWhileHot(
        interval: Duration = .seconds(10),
        maximumWait: Duration = .seconds(120)
    ) async {
        var waited = Duration.zero
        while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
              waited < maximumWait, !Task.isCancelled {
            if waited == .zero {
                Logger.processing.info("Device is hot, pausing processing")
            }
            try? await Task.sleep(for: interval)
            waited += interval
        }
    }
}
