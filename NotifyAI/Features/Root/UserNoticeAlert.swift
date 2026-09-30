//
//  UserNoticeAlert.swift
//  NotifyAI
//

import DesignSystem
import SwiftUI

extension View {
    /// Presents pending `UserNotices`. Attached to the root view and to screens that cover
    /// it (the full-screen recorder on iOS); only the frontmost one is active.
    func userNoticeAlert(isActive: Bool = true) -> some View {
        modifier(UserNoticeAlertModifier(isActive: isActive))
    }
}

private struct UserNoticeAlertModifier: ViewModifier {
    let isActive: Bool
    @Environment(UserNotices.self) private var notices
    @Environment(AppNavigation.self) private var navigation

    func body(content: Content) -> some View {
        let notice = isActive ? notices.current : nil
        content
            .alert(
                notice?.title ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notices.dismissCurrent() } }
                ),
                presenting: notice
            ) { notice in
                if let noteID = notice.noteID {
                    Button("Notiz öffnen") {
                        navigation.open(noteID: noteID)
                        notices.dismissCurrent()
                    }
                }
                Button("OK", role: .cancel) {
                    notices.dismissCurrent()
                }
            } message: { notice in
                Text(notice.message)
            }
    }
}
