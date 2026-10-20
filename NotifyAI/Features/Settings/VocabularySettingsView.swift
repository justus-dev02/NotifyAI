//
//  VocabularySettingsView.swift
//  NotifyAI
//

import NotifyAIServices
import SwiftUI

/// Names and terms the speech recognition should know.
struct VocabularySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var newTerm = ""

    var body: some View {
        @Bindable var transcription = settings.transcription

        Form {
            Section {
                HStack {
                    TextField("Name oder Begriff", text: $newTerm)
                        .onSubmit(add)
                    Button("Hinzufügen", systemImage: "plus.circle.fill", action: add)
                        .labelStyle(.iconOnly)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(transcription.vocabulary, id: \.self) { term in
                    Text(term)
                        .contextMenu {
                            Button("Entfernen", systemImage: "trash", role: .destructive) { remove(term) }
                        }
                }
                .onDelete { offsets in
                    transcription.vocabulary.remove(atOffsets: offsets)
                }
            } footer: {
                Text("Namen von Personen, Produkten und Projekten sowie Fachbegriffe, so geschrieben, wie sie im Transkript stehen sollen. Whisper und Apple Speech bevorzugen diese Schreibweisen; bei Parakeet werden fast gleiche Wörter danach korrigiert. Gilt für neue Transkripte.")
            }
        }
        .formStyle(.grouped)
        .settingsPage("Eigenes Vokabular")
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if !settings.transcription.vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            settings.transcription.vocabulary.append(term)
        }
        newTerm = ""
    }

    private func remove(_ term: String) {
        settings.transcription.vocabulary.removeAll { $0 == term }
    }
}
