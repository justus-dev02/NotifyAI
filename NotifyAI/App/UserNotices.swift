//
//  UserNotices.swift
//  NotifyAI
//

import Foundation
import NotifyAICore
import NotifyAIPersistence
import NotifyAIServices
import Observation

/// A message about something that went wrong outside of a direct user action, e.g. a
/// change that could not be saved or a recording that stopped because the disk was full.
struct UserNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    /// The note the notice is about; the alert then offers to open it.
    var noteID: UUID?
}

/// Collects notices and shows them one after another. Failures are never swallowed
/// silently: the services report them as events, this type turns them into text and
/// `RootView` presents them.
@MainActor
@Observable
final class UserNotices {
    private(set) var pending: [UserNotice] = []

    var current: UserNotice? { pending.first }

    @ObservationIgnored private var subscriptions: [EventSubscription] = []

    init() {}

    /// Follows the failures of the store and the automatic stops of recordings.
    convenience init(store: NoteStore, recording: RecordingController) {
        self.init()
        store.events.subscribe { [weak self] event in
            self?.storeDidReport(event)
        }.store(in: &subscriptions)
        recording.events.subscribe { [weak self] event in
            self?.recordingDidReport(event)
        }.store(in: &subscriptions)
    }

    func post(_ notice: UserNotice) {
        // The same failure repeated (e.g. every save while the disk is full) is shown once.
        guard !pending.contains(where: { $0.title == notice.title && $0.message == notice.message }) else { return }
        pending.append(notice)
    }

    func dismissCurrent() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()
    }

    // MARK: - Events

    private func storeDidReport(_ event: NoteStoreEvent) {
        switch event {
        case .saveFailed(let error):
            post(UserNotice(
                title: String(localized: "Nicht gespeichert"),
                message: String(localized: "Die Änderung konnte nicht gespeichert werden: \(error.localizedDescription)")
            ))
        case .deleteFailed(let error):
            post(UserNotice(
                title: String(localized: "Nicht gelöscht"),
                message: String(localized: "Die Notiz konnte nicht gelöscht werden: \(error.localizedDescription)")
            ))
        case .saved, .deleted:
            break
        }
    }

    private func recordingDidReport(_ event: RecordingEvent) {
        switch event {
        case .stoppedAutomatically(let noteID, let reason):
            post(UserNotice(title: String(localized: "Aufnahme beendet"), message: reason.message, noteID: noteID))
        }
    }
}

extension AutomaticStopReason {
    /// Why the recording stopped, and that nothing recorded is lost.
    var message: String {
        switch self {
        case .writeFailed(let reason):
            String(localized: "Die Audiodatei konnte nicht weiter geschrieben werden (\(reason)). Alles bis zu diesem Zeitpunkt Aufgenommene ist gespeichert.")
        case .lowDiskSpace(let available):
            String(localized: "Auf dem Gerät sind nur noch \(TimeFormatting.byteCount(available)) frei. Die Aufnahme wurde beendet, bevor der Speicher voll ist; alles bisher Aufgenommene ist gespeichert.")
        }
    }
}

extension RecordingPauseReason {
    /// Why the recording paused, and what the user can do.
    var message: String {
        switch self {
        case .systemInterruption:
            String(localized: "Die Aufnahme wurde vom System unterbrochen, z. B. durch einen Anruf.")
        case .deviceUnavailable(let reason):
            String(localized: "Die Aufnahme wurde pausiert, weil das Audiogerät nicht mehr verfügbar ist (\(reason)). Alles bis hierhin ist gespeichert. Setze sie fort, sobald das Gerät wieder bereit ist.")
        case .systemSleep:
            String(localized: "Die Aufnahme wurde pausiert, weil der Mac in den Ruhezustand gewechselt ist. Setze sie fort, sobald das Gespräch weitergeht.")
        }
    }
}
