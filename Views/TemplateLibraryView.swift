import SwiftUI

struct TemplateLibraryView: View {
    @State private var templates: [NoteTemplate] = TemplateLibraryView.defaultTemplates
    @State private var selectedAudience: NoteTemplate.Audience? = nil
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section("Filter") {
                Picker("Rolle", selection: $selectedAudience) {
                    Text("Alle").tag(NoteTemplate.Audience?.none)
                    ForEach(NoteTemplate.Audience.allCases) { audience in
                        Text(audience.displayName).tag(Optional(audience))
                    }
                }
                .pickerStyle(.segmented)
            }

            ForEach(filteredTemplates) { template in
                VStack(alignment: .leading, spacing: 8) {
                    Text(template.title)
                        .font(.headline)
                    Text(template.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(template.audiences) { audience in
                            Text(audience.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("Vorlagen-Katalog")
    }

    private var filteredTemplates: [NoteTemplate] {
        guard let selectedAudience else { return templates }
        return templates.filter { $0.audiences.contains(selectedAudience) }
    }
}

extension TemplateLibraryView {
    static let defaultTemplates: [NoteTemplate] = [
        NoteTemplate(title: "Vertriebscall",
                     description: "Deal-Health, Einwände, Nächste Schritte",
                     defaultPrompt: "Fasse für Sales zusammen",
                     audiences: [.sales, .leadership]),
        NoteTemplate(title: "1:1 Meeting",
                     description: "Ziele, Blocker, Kudos",
                     defaultPrompt: "Erstelle Coaching Summary",
                     audiences: [.team]),
        NoteTemplate(title: "Daily Scrum",
                     description: "Gestern/Heute/Blocker",
                     defaultPrompt: "Zusammenfassung für Product Owner",
                     audiences: [.team, .product]),
        NoteTemplate(title: "User Interview",
                     description: "Insights, Zitate, Jobs to be Done",
                     defaultPrompt: "UX Research Fokus",
                     audiences: [.product, .leadership]),
        NoteTemplate(title: "Vorlesung",
                     description: "Kapitel, Lernziele, Aufgaben",
                     defaultPrompt: "Studierenden-Summary",
                     audiences: [.education])
    ]
}

#Preview {
    NavigationStack { TemplateLibraryView() }
}
