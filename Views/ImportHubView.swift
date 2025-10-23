import SwiftUI

struct ImportHubView: View {
    @EnvironmentObject private var viewModel: NotesViewModel
    @State private var urlString: String = "https://beispiel.de/article"
    @State private var youtubeURL: String = "https://youtu.be/demo"
    @State private var isShowingFilePicker = false
    @State private var isShowingScanner = false
    @State private var importTasks: [ImportTask] = ImportTask.sample
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    captureSection
                    taskSection
                }
                .padding(.vertical, 24)
            }
            .background(LinearGradient(colors: [Color(hex: "#EAF3FF") ?? .blue.opacity(0.1), Color.white], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
            .navigationTitle("Capture Hub")
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Importiere Web, Video, PDF oder Scans")
                .font(.headline)
            VStack(spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Web-Artikel & PDFs", systemImage: "safari.fill")
                            .font(.title3)
                        TextField("https://", text: $urlString)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Reader-Modus extrahieren") {
                                importTasks.append(.init(title: "Web-Extraktion", detail: urlString, stage: .queued))
                            }
                            .buttonStyle(.borderedProminent)
                            Button("PDF hochladen") {
                                isShowingFilePicker = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("YouTube & Video", systemImage: "play.rectangle.fill")
                            .font(.title3)
                        TextField("https://youtu.be/...", text: $youtubeURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Transkript & Kapitel ziehen") {
                            importTasks.append(.init(title: "YouTube-Transkript", detail: youtubeURL, stage: .processing))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Bild-Scan & OCR", systemImage: "viewfinder.rectangular")
                            .font(.title3)
                        Text("Scanne Whiteboards, handschriftliche Notizen oder Dokumente.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Scan starten") { isShowingScanner = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Laufende Importe")
                .font(.headline)
                .padding(.horizontal, 24)

            ForEach(importTasks) { task in
                GlassCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title)
                                .font(.headline)
                            Text(task.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PipelineChip(state: task.pipelineState)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

struct ImportTask: Identifiable, Hashable {
    enum Stage: String, CaseIterable {
        case queued
        case processing
        case completed
    }

    let id: UUID
    var title: String
    var detail: String
    var stage: Stage

    init(id: UUID = UUID(), title: String, detail: String, stage: Stage) {
        self.id = id
        self.title = title
        self.detail = detail
        self.stage = stage
    }

    var pipelineState: PipelineState {
        switch stage {
        case .queued:
            return .init(stage: .chunking, progress: 0.1)
        case .processing:
            return .init(stage: .summarizing, progress: 0.5)
        case .completed:
            return .init(stage: .done, progress: 1.0)
        }
    }
}

extension ImportTask {
    static let sample: [ImportTask] = [
        .init(title: "FAZ.de – KI Artikel", detail: "Reader + Summary", stage: .completed),
        .init(title: "YouTube – WWDC Session", detail: "Kapitel & Transcript", stage: .processing)
    ]
}

struct GlassCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}

#Preview {
    ImportHubView()
        .environmentObject(NotesViewModel())
}
