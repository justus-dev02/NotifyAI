//
//  ConsentSheet.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct ConsentSheet: View {
    @Binding var isPresented: Bool
    @Binding var confirmed: Bool
    let participantsInput: String
    let locationInput: String

    var onConfirm: (_ log: ConsentLog) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.indigo)
                        .padding(.top, 12)
                    
                    Text("Aufnahme-Zustimmung")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Bitte stelle sicher, dass alle anwesenden Personen der Aufzeichnung zugestimmt haben.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if !participantsInput.isEmpty {
                        HStack {
                            Label("Teilnehmer:", systemImage: "person.2.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(participantsInput)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    }
                    
                    if !locationInput.isEmpty {
                        HStack {
                            Label("Ort:", systemImage: "mappin.and.ellipse")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(locationInput)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 16) {
                    Toggle(isOn: $confirmed) {
                        Text("Ich habe die ausdrückliche Zustimmung aller Anwesenden.")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .tint(.indigo)
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(confirmed ? Color.indigo.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                }

                Spacer()

                HStack(spacing: 16) {
                    Button("Abbrechen") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button {
                        let logList = participantsInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        let log = ConsentManager.shared.makeConsentLog(
                            participants: logList,
                            location: locationInput.isEmpty ? nil : locationInput,
                            confirmed: confirmed
                        )
                        onConfirm(log)
                        isPresented = false
                    } label: {
                        Text("Aufnahme starten")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(confirmed ? Color.indigo : Color.gray.opacity(0.3))
                    .disabled(!confirmed)
                }
                .padding(.bottom, 12)
            }
            .padding(24)
            .background(
                LinearGradient(
                    colors: [Color.adaptiveBackground, Color.indigo.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
