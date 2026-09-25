//
//  TemplateLibraryView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Interactive Template Selection & Live Recording Initialization.
//

import SwiftUI

struct TemplateLibraryView: View {
    @State private var templates: [NoteTemplate] = NoteTemplate.defaultTemplates
    @State private var selectedAudience: NoteTemplate.Audience? = nil
    @State private var selectedTemplateForRecording: NoteTemplate? = nil
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                // Audience Filter Pills
                filterPills

                // Template Cards
                LazyVStack(spacing: 14) {
                    ForEach(filteredTemplates) { template in
                        templateCard(template)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .padding(.top, 12)
        }
        .liquidGlassBackground()
        .navigationTitle("Vorlagen-Katalog")
        .sheet(item: $selectedTemplateForRecording) { template in
            UnifiedRecordingView(
                note: Note(title: template.title),
                prefilledContext: template.placeholderContext
            )
            .environmentObject(notesViewModel)
            .environmentObject(themeManager)
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pillButton(title: "Alle", isSelected: selectedAudience == nil) {
                    selectedAudience = nil
                }

                ForEach(NoteTemplate.Audience.allCases) { aud in
                    pillButton(title: aud.displayName, isSelected: selectedAudience == aud) {
                        selectedAudience = aud
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func pillButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(isSelected ? Color.white : Color.adaptiveLabel)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.indigo : Color.clear, in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(isSelected ? Color.indigo : Color.white.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private func templateCard(_ template: NoteTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(template.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.adaptiveLabel)

                Spacer()

                HStack(spacing: 4) {
                    ForEach(template.audiences) { audience in
                        Image(systemName: audience.icon)
                            .font(.caption)
                            .foregroundStyle(Color.indigo)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.indigo.opacity(0.12), in: Capsule())
            }

            Text(template.description)
                .font(.subheadline)
                .foregroundStyle(Color.adaptiveSecondaryLabel)
                .lineLimit(2)

            if !template.placeholderContext.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Beispiel: \(template.placeholderContext)")
                        .font(.caption2)
                        .foregroundStyle(Color.adaptiveTertiaryLabel)
                }
            }

            Button {
                selectedTemplateForRecording = template
            } label: {
                HStack {
                    Image(systemName: "waveform.badge.plus")
                    Text("Aufnahme mit dieser Vorlage starten")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.indigo.opacity(0.3), radius: 6, y: 3)
            }
            .padding(.top, 4)
        }
        .liquidGlassCard(cornerRadius: 20, padding: 16)
    }

    private var filteredTemplates: [NoteTemplate] {
        guard let selectedAudience else { return templates }
        return templates.filter { $0.audiences.contains(selectedAudience) }
    }
}

#Preview {
    NavigationStack {
        TemplateLibraryView()
            .environmentObject(AppState())
            .environmentObject(NotesViewModel())
            .environmentObject(ThemeManager())
    }
}
