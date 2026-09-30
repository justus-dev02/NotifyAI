//
//  DatabaseRecoveryView.swift
//  NotifyAI
//

import DesignSystem
import SwiftUI

/// Shown instead of the app when the database cannot be opened.
struct DatabaseRecoveryView: View {
    let launch: AppLaunch
    @State private var isConfirmingReset = false
    @State private var isResetting = false

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.small) {
                Text("Die Notizen können nicht geöffnet werden")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Die Datenbank von NotifyAI ist beschädigt oder konnte nicht aktualisiert werden. Deine Aufnahmen sind davon nicht betroffen.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let failure = launch.failure {
                    Text(failure)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }

            VStack(spacing: Theme.Spacing.medium) {
                Button("Erneut versuchen") {
                    launch.attempt()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button("Datenbank zurücksetzen …", role: .destructive) {
                    isConfirmingReset = true
                }
                .disabled(isResetting)

                DiagnosticsExportButton()
            }

            if isResetting {
                ProgressView("Aufnahmen werden wiederhergestellt …")
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Datenbank zurücksetzen?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) {
                isResetting = true
                Task {
                    await launch.resetDatabase()
                    isResetting = false
                }
            }
        } message: {
            Text("Die bisherige Datenbank wird nicht gelöscht, sondern in den Ordner „Recovery“ verschoben. Alle Aufnahmen werden als neue Notizen angelegt und erneut transkribiert und zusammengefasst. Bearbeitete Titel, Markierungen und erledigte Aufgaben gehen dabei verloren.")
        }
    }
}
