//
//  OnboardingCard.swift
//  NotifyAI
//
//  Created by Justus on 23.10.25.
//

import SwiftUI

struct OnboardingCard<Content: View>: View {
    let icon: String
    let title: String
    let step: OnboardingViewModel.Step
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2)
                        .bold()
                    Text("Schritt \(step.rawValue + 1) von \(OnboardingViewModel.Step.allCases.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }
}
