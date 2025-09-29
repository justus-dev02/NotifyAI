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
    @State private var participants = ""
    @State private var location = ""

    var onConfirm: (_ log: ConsentLog) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Teilnehmer (optional)") {
                    TextField("z. B. Max, Lea, Team X", text: $participants)
                    TextField("Ort", text: $location)
                }
                Section {
                    Toggle("Ich habe die ausdrückliche Zustimmung aller Anwesenden.", isOn: $confirmed)
                } footer: {
                    Text("Bitte beachte lokale Gesetze & Unternehmensrichtlinien.")
                }
            }
            .navigationTitle("Aufnahme-Zustimmung")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let log = ConsentManager.shared.makeConsentLog(
                            participants: participants.split(separator: ",").map{ $0.trimmingCharacters(in: .whitespaces) },
                            location: location.isEmpty ? nil : location,
                            confirmed: confirmed
                        )
                        onConfirm(log)
                        isPresented = false
                    }.disabled(!confirmed)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { isPresented = false }
                }
            }
        }
    }
}
