//
//  BackgroundProcessingScheduler.swift
//  NotifyAI
//

#if os(iOS)
import BackgroundTasks
import Foundation
import NotifyAICore
import NotifyAIServices
import OSLog
import UIKit

/// Lets long processing continue when the user leaves the app (iOS / iPadOS).
///
/// Two mechanisms:
/// - **Continued processing** (`BGContinuedProcessingTask`, iOS 26): when a long recording
///   starts processing while the app is open, the system is asked to keep it running in the
///   background. iOS shows the progress in a system UI and may end the task when resources
///   get scarce or the user cancels it.
/// - **Overnight processing** (`BGProcessingTask`): when the app goes to the background with
///   unfinished work, a task is scheduled that runs while the device charges.
///
/// Either way, an ended task interrupts the job cleanly: it keeps its saved steps
/// (transcript, chapter digests) and continues at the next opportunity.
@MainActor
final class BackgroundProcessingScheduler {
    static let continuedIdentifierPrefix = "com.justus.NotifyAI.processing.continued"
    static let overnightIdentifier = "com.justus.NotifyAI.processing.overnight"
    /// Recordings shorter than this finish within the normal background time.
    static let minimumDurationForContinuedTask: TimeInterval = 10 * 60

    private let processing: ProcessingCoordinator
    private let logger = Logger.processing
    private var continuedTask: BGContinuedProcessingTask?
    private var isSubmittingContinuedTask = false
    private var monitor: Task<Void, Never>?
    private var subscription: EventSubscription?

    /// Follows the processing's jobs: long recordings get a continued processing task.
    init(processing: ProcessingCoordinator) {
        self.processing = processing
        subscription = processing.events.subscribe { [weak self] event in
            switch event {
            case .jobStarted(let noteID, let duration):
                self?.jobStarted(noteID: noteID, duration: duration)
            }
        }
    }

    /// Must be called before the app finishes launching.
    func registerOvernightTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.overnightIdentifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else { return }
                self?.runOvernight(task)
            }
        }
        if !registered {
            logger.error("Registering the overnight processing task failed")
        }
    }

    // MARK: - Continued processing

    /// Long recordings get a continued processing task, so they finish even if the user
    /// switches to another app.
    private func jobStarted(noteID: UUID, duration: TimeInterval) {
        guard duration >= Self.minimumDurationForContinuedTask,
              continuedTask == nil, !isSubmittingContinuedTask,
              // Only the app in the foreground may submit (the request is user initiated).
              UIApplication.shared.applicationState == .active
        else { return }

        // Unique per submission: registering an identifier twice is not allowed.
        let identifier = "\(Self.continuedIdentifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                self?.runContinued(task)
            }
        }
        guard registered else {
            logger.error("Registering the continued processing task failed")
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "Aufnahme wird verarbeitet"),
            subtitle: String(localized: "Transkript und Zusammenfassung")
        )
        // Fail instead of queueing: a queued request would start later without the app.
        request.strategy = .fail
        do {
            isSubmittingContinuedTask = true
            try BGTaskScheduler.shared.submit(request)
        } catch {
            isSubmittingContinuedTask = false
            logger.error("Submitting the continued processing task failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runContinued(_ task: BGContinuedProcessingTask) {
        isSubmittingContinuedTask = false
        continuedTask = task
        task.progress.totalUnitCount = 1_000
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                self?.logger.info("Continued processing expired")
                self?.processing.interruptCurrentJob()
                self?.finishContinuedTask(success: false)
            }
        }
        processing.resumeQueuedWork()
        startMonitoring()
    }

    /// Reports progress regularly (tasks without progress are treated as stalled) and
    /// completes the task when all work is done.
    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = continuedTask else { return }
                if !processing.hasPendingWork {
                    task.progress.completedUnitCount = task.progress.totalUnitCount
                    finishContinuedTask(success: true)
                    return
                }
                task.progress.completedUnitCount = Int64(processing.overallProgress * 1_000)
                if let stage = processing.currentStage {
                    task.updateTitle(String(localized: "Aufnahme wird verarbeitet"), subtitle: stage.displayName)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func finishContinuedTask(success: Bool) {
        monitor?.cancel()
        monitor = nil
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
    }

    // MARK: - Overnight processing

    /// Called when the app moves to the background: unfinished work is scheduled for a time
    /// when the device is charging.
    func scheduleOvernightProcessingIfNeeded() {
        guard processing.hasPendingWork, continuedTask == nil else { return }
        let request = BGProcessingTaskRequest(identifier: Self.overnightIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Scheduling overnight processing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runOvernight(_ task: BGProcessingTask) {
        let work = Task { [weak self] in
            guard let self else { return }
            processing.resumePendingWork()
            processing.resumeQueuedWork()
            while processing.hasPendingWork, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
            }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { [weak self] in
            MainActor.assumeIsolated {
                self?.processing.interruptCurrentJob()
                // The work task ends and reports completion exactly once.
                work.cancel()
            }
        }
    }
}
#endif
