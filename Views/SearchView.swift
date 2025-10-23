import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var viewModel: NotesViewModel
    @State private var selectedFacet: Facet = .allTime
    @State private var selectedParticipants: Set<Participant> = []
    @State private var selectedSource: SourceType? = nil
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                searchField
                filterChips
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        semanticResultsSection
                        fulltextSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .padding(.top, 16)
            .navigationTitle("Suche")
        }
        .onChange(of: viewModel.query) { _ in viewModel.performSearch() }
    }

    private var searchField: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Suche in Notizen, Transkripten und Importen", text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))

            Button {
                viewModel.performSearch()
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Facet.allCases) { facet in
                    ChipView(title: facet.label, isSelected: facet == selectedFacet) {
                        selectedFacet = facet
                    }
                }

                ChipView(title: selectedSource?.displayName ?? "Quelle: Alle", isSelected: selectedSource != nil) {
                    cycleSource()
                }

                ChipView(title: participantLabel, isSelected: !selectedParticipants.isEmpty) {
                    selectedParticipants = .init(sampleParticipants.prefix(2))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var semanticResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Semantische Treffer")
                .font(.headline)
            ForEach(viewModel.results.prefix(5)) { note in
                SearchResultRow(note: note, kind: .semantic)
            }
        }
    }

    private var fulltextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volltext")
                .font(.headline)
            ForEach(viewModel.results) { note in
                SearchResultRow(note: note, kind: .keyword)
            }
        }
    }

    private var sampleParticipants: [Participant] {
        viewModel.results.flatMap { $0.participants }
    }

    private var participantLabel: String {
        if selectedParticipants.isEmpty { return "Teilnehmer" }
        let names = selectedParticipants.map(\.name).sorted()
        return "Teilnehmer: \(names.joined(separator: ", "))"
    }

    private func cycleSource() {
        if let source = selectedSource, let index = SourceType.allCases.firstIndex(of: source) {
            let nextIndex = SourceType.allCases.index(after: index)
            selectedSource = nextIndex < SourceType.allCases.endIndex ? SourceType.allCases[nextIndex] : nil
        } else {
            selectedSource = SourceType.allCases.first
        }
    }

    enum Facet: String, CaseIterable, Identifiable {
        case today
        case week
        case month
        case allTime

        var id: String { rawValue }

        var label: String {
            switch self {
            case .today: return "Heute"
            case .week: return "7 Tage"
            case .month: return "30 Tage"
            case .allTime: return "Alle Zeiten"
            }
        }
    }
}

struct ChipView: View {
    let title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.001), in: Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.accentColor : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SearchResultRow: View {
    let note: Note

    enum Kind {
        case semantic
        case keyword
    }

    var kind: Kind

    var body: some View {
        NavigationLink(destination: NoteDetailView(note: note)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(note.sourceType.displayName, systemImage: note.sourceType.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(kind == .semantic ? "Semantisch" : "Volltext")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(kind == .semantic ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15), in: Capsule())
                }

                Text(note.title)
                    .font(.headline)
                Text(snippet(from: note))
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    func snippet(from note: Note) -> String {
        note.summary?.markdown.split(separator: "\n").first.map(String.init) ??
        note.segments.first?.text ??
        "Keine Vorschau verfügbar"
    }
}

#Preview {
    SearchView()
        .environmentObject(NotesViewModel())
}
