import SwiftUI

struct ProgressOverlayView: View {
    let steps: [ProcessingStep]
    var onDismiss: () -> Void

    init(steps: [ProcessingStep], onDismiss: @escaping () -> Void) {
        self.steps = steps
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .frame(width: 40, height: 4)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 16) {
                Text("Post-Processing")
                    .font(.title2)
                    .bold()
                Text("Deine Aufnahme wird lokal verarbeitet. Du kannst die App weiter nutzen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    HStack(spacing: 12) {
                        Image(systemName: step.icon)
                            .font(.title3)
                            .foregroundStyle(step.state == .active ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .font(.headline)
                            Text(step.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if step.state == .active {
                            ProgressView(value: step.progress)
                                .frame(width: 80)
                        } else if step.state == .done {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
            }

            Button("In Hintergrund verarbeiten", action: onDismiss)
                .buttonStyle(.bordered)
            Text("Du kannst jetzt weiter aufnehmen")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(24)
    }
}

struct ProcessingStep: Identifiable {
    enum State {
        case pending
        case active
        case done
    }

    let id = UUID()
    var icon: String
    var title: String
    var subtitle: String
    var state: State
    var progress: Double

    static func build(from pipeline: PipelineState) -> [ProcessingStep] {
        PipelineState.Stage.progression.map { stage in
            ProcessingStep(icon: icon(for: stage),
                           title: title(for: stage),
                           subtitle: subtitle(for: stage),
                           state: state(for: stage, pipeline: pipeline),
                           progress: stage == pipeline.stage ? pipeline.progress : 1.0)
        }
    }

    private static func icon(for stage: PipelineState.Stage) -> String {
        switch stage {
        case .chunking: return "waveform"
        case .transcribing: return "text.quote"
        case .diarizing: return "person.2.wave.2.fill"
        case .summarizing: return "list.bullet.rectangle"
        case .roleSummaries: return "person.crop.square.fill.and.at.rectangle"
        case .mindmap: return "tree"
        case .indexing: return "magnifyingglass.circle"
        case .done: return "checkmark.circle"
        case .none, .error: return "exclamationmark.triangle"
        }
    }

    private static func title(for stage: PipelineState.Stage) -> String {
        switch stage {
        case .chunking: return "Sprache analysiert"
        case .transcribing: return "Diarization"
        case .diarizing: return "Sprecherzuordnung"
        case .summarizing: return "TODOs & Summary"
        case .roleSummaries: return "Rollen-Sichten"
        case .mindmap: return "Mindmap"
        case .indexing: return "Semantischer Index"
        case .done: return "Fertig"
        case .none, .error: return "Fehler"
        }
    }

    private static func subtitle(for stage: PipelineState.Stage) -> String {
        switch stage {
        case .chunking: return "Chunking & VAD-Glättung"
        case .transcribing: return "WhisperKit + Wort-Timestamps"
        case .diarizing: return "Speaker Re-ID & Merge"
        case .summarizing: return "Kurz & ausführlich"
        case .roleSummaries: return "JSON Schema & Validator"
        case .mindmap: return "Drag & Drop Strukturen"
        case .indexing: return "Hybrid Search Aufbau"
        case .done: return "Alles abgeschlossen"
        case .none, .error: return "Fehler bitte prüfen"
        }
    }

    private static func state(for stage: PipelineState.Stage, pipeline: PipelineState) -> State {
        if stage == pipeline.stage { return .active }
        if stage.rawValue < pipeline.stage.rawValue { return .done }
        return .pending
    }
}

#Preview {
    ProgressOverlayView(steps: ProcessingStep.build(from: .init(stage: .summarizing, progress: 0.4))) {}
}
