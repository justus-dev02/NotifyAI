//
//  LockView.swift
//  NotifyAI
//

import DesignSystem
import SwiftUI

/// Covers the interface until the user authenticates.
struct LockView: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(spacing: Theme.Spacing.small) {
                Text("NotifyAI ist gesperrt")
                    .font(.title2.bold())
                Text("Entsperre die App, um deine Notizen zu sehen.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let message = appLock.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await appLock.unlock() }
            } label: {
                Label("Mit \(AppLock.biometryName) entsperren", systemImage: "faceid")
                    .padding(.horizontal, Theme.Spacing.small)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(appLock.isAuthenticating)
        }
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
