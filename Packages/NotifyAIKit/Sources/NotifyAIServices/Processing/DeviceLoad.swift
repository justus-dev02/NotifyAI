//
//  DeviceLoad.swift
//  NotifyAIServices
//

import Foundation
import NotifyAICore
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

    private static var isHot: Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// Waits while the device is hot, but never longer than `maximumWait`: the work has to
    /// finish eventually.
    ///
    /// Event-driven: the task sleeps until the system reports a thermal state change
    /// (`thermalStateDidChangeNotification`) instead of waking up to poll.
    static func waitWhileHot(maximumWait: Duration = .seconds(120)) async {
        guard isHot, !Task.isCancelled else { return }
        Logger.processing.info("Device is hot, pausing processing")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let changes = NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification)
                    .map { _ in () }
                // The state may have changed between the check above and subscribing.
                guard isHot else { return }
                for await _ in changes where !isHot {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(for: maximumWait)
            }
            // Whichever finishes first (cooled down, timeout or cancellation) ends the wait.
            await group.next()
            group.cancelAll()
        }
        Logger.processing.info("Resuming processing (thermal state \(ProcessInfo.processInfo.thermalState.rawValue, privacy: .public))")
    }
}
