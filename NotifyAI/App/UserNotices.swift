//
//  UserNotices.swift
//  NotifyAI
//

import Foundation
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
/// silently: services post here, `RootView` presents them.
@MainActor
@Observable
final class UserNotices {
    private(set) var pending: [UserNotice] = []

    var current: UserNotice? { pending.first }

    func post(_ notice: UserNotice) {
        // The same failure repeated (e.g. every save while the disk is full) is shown once.
        guard !pending.contains(where: { $0.title == notice.title && $0.message == notice.message }) else { return }
        pending.append(notice)
    }

    func dismissCurrent() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()
    }
}
