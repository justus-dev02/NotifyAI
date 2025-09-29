//
//  NoteDetailView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct NoteDetailView: View {
    let note: Note

    var body: some View {
        List {
            if let summary = note.summary {
                Section("Zusammenfassung") {
                    Text(summary.markdown.isEmpty ? "Keine Zusammenfassung verfügbar." : summary.markdown)
                }
            }

            if !note.segments.isEmpty {
                Section("Transkript") {
                    ForEach(note.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(timeString(segment.start))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let speaker = segment.speakerId {
                                    Text(speaker)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(segment.text)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(note.title)
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    var note = Note(title: "Besprechung")
    note.summary = Summary(highlights: ["Point"], markdown: "**Markdown**")
    note.segments = [TranscriptSegment(start: 0, end: 10, speakerId: "Sprecher 1", text: "Hallo zusammen")]
    return NavigationStack { NoteDetailView(note: note) }
}
