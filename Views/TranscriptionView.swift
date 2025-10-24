//
//  TranscriptionView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//
/*
import SwiftUI
import AVFoundation

struct TranscriptionView: View {
    @StateObject private var viewModel = RealTimeTranscriptionViewModel()
    @StateObject private var transcriber = SpeechTranscriber.shared
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedMode: TranscriptionMode = .realTime
    @State private var selectedFile: URL?
    @State private var isShowingFilePicker = false
    @State private var isShowingResults = false
    @State private var transcriptResult: TranscriptResult?
    
    enum TranscriptionMode: String, CaseIterable, Identifiable {
        case realTime = "realTime"
        case file = "file"
        case batch = "batch"
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .realTime: return "Live-Transkription"
            case .file: return "Datei-Transkription"
            case .batch: return "Batch-Transkription"
            }
        }
        
        var description: String {
            switch self {
            case .realTime: return "Sprache in Echtzeit transkribieren"
            case .file: return "Audio-Datei hochladen und transkribieren"
            case .batch: return "Mehrere Dateien gleichzeitig verarbeiten"
            }
        }
        
        var icon: String {
            switch self {
            case .realTime: return "mic.fill"
            case .file: return "doc.fill"
            case .batch: return "folder.fill"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    modeSelectionSection
                    contentSection
                }
                .padding(24)
            }
            .themedBackground(.primary)
            .navigationTitle("Sprach-Transkription")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isShowingFilePicker) {
                DocumentPicker(selectedFile: $selectedFile)
            }
            .sheet(isPresented: $isShowingResults) {
                if let result = transcriptResult {
                    TranscriptionResultsView(result: result)
                }
            }
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.accent)
            
            Text("Sprache zu Text konvertieren")
                .font(.title2)
                .fontWeight(.bold)
                .themedText(.primary)
            
            Text("Wähle den Transkriptionsmodus und starte die Konvertierung")
                .font(.body)
                .themedText(.secondary)
                .multilineTextAlignment(.center)
        }
        .glassCard()
    }
    
    // MARK: - Mode Selection
    private var modeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transkriptionsmodus")
                .font(.headline)
                .themedText(.primary)
            
            VStack(spacing: 12) {
                ForEach(TranscriptionMode.allCases) { mode in
                    TranscriptionModeCard(
                        mode: mode,
                        isSelected: selectedMode == mode
                    ) {
                        selectedMode = mode
                    }
                }
            }
        }
        .glassCard()
    }
    
    // MARK: - Content Section
    @ViewBuilder
    private var contentSection: some View {
        switch selectedMode {
        case .realTime:
            realTimeTranscriptionView
        case .file:
            fileTranscriptionView
        case .batch:
            batchTranscriptionView
        }
    }
    
    // MARK: - Real-time Transcription
    private var realTimeTranscriptionView: some View {
        VStack(spacing: 20) {
            // Status
            HStack {
                Circle()
                    .fill(viewModel.isTranscribing ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                
                Text(viewModel.isTranscribing ? "Transkribiert..." : "Bereit")
                    .font(.headline)
                    .themedText(.primary)
                
                Spacer()
                
                if viewModel.confidence > 0 {
                    Text("Genauigkeit: \(Int(viewModel.confidence * 100))%")
                        .font(.caption)
                        .themedText(.secondary)
                }
            }
            
            // Live Text Display
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !viewModel.currentText.isEmpty {
                        Text("Live-Text:")
                            .font(.caption)
                            .themedText(.secondary)
                        
                        Text(viewModel.currentText)
                            .font(.body)
                            .themedText(.primary)
                            .padding()
                            .background(AppTheme.secondaryBackground)
                            .cornerRadius(12)
                    }
                    
                    if !viewModel.finalText.isEmpty {
                        Text("Finaler Text:")
                            .font(.caption)
                            .themedText(.secondary)
                        
                        Text(viewModel.finalText)
                            .font(.body)
                            .themedText(.primary)
                            .padding()
                            .background(AppTheme.accent.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
            }
            .frame(maxHeight: 300)
            
            // Controls
            HStack(spacing: 16) {
                if viewModel.isTranscribing {
                    Button("Stop") {
                        viewModel.stopTranscription()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                } else {
                    Button("Start") {
                        viewModel.startTranscription()
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                if !viewModel.finalText.isEmpty {
                    Button("Ergebnis anzeigen") {
                        transcriptResult = TranscriptResult(
                            text: viewModel.finalText,
                            confidence: viewModel.confidence,
                            segments: [],
                            language: "de-DE"
                        )
                        isShowingResults = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .glassCard()
    }
    
    // MARK: - File Transcription
    private var fileTranscriptionView: some View {
        VStack(spacing: 20) {
            // File Selection
            VStack(spacing: 16) {
                if let selectedFile = selectedFile {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundColor(AppTheme.accent)
                        Text(selectedFile.lastPathComponent)
                            .font(.subheadline)
                            .themedText(.primary)
                        Spacer()
                        Button("Entfernen") {
                            self.selectedFile = nil
                        }
                        .font(.caption)
                        .themedText(.secondary)
                    }
                    .padding()
                    .background(AppTheme.secondaryBackground)
                    .cornerRadius(12)
                } else {
                    Button(action: { isShowingFilePicker = true }) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
                                .foregroundColor(AppTheme.accent)
                            Text("Audio-Datei auswählen")
                                .font(.headline)
                                .themedText(.primary)
                            Text("MP3, M4A, WAV unterstützt")
                                .font(.caption)
                                .themedText(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(32)
                        .background(AppTheme.secondaryBackground)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Progress
            if transcriber.isProcessing {
                VStack(spacing: 12) {
                    ProgressView(value: transcriber.processingProgress)
                        .tint(AppTheme.accent)
                    
                    Text("Verarbeitung: \(Int(transcriber.processingProgress * 100))%")
                        .font(.caption)
                        .themedText(.secondary)
                }
            }
            
            // Controls
            HStack(spacing: 16) {
                Button("Transkribieren") {
                    guard let file = selectedFile else { return }
                    transcribeFile(file)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFile == nil || transcriber.isProcessing)
                
                if !transcriber.isProcessing && selectedFile != nil {
                    Button("Datei erneut auswählen") {
                        isShowingFilePicker = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .glassCard()
    }
    
    // MARK: - Batch Transcription
    private var batchTranscriptionView: some View {
        VStack(spacing: 20) {
            Text("Batch-Transkription")
                .font(.headline)
                .themedText(.primary)
            
            Text("Mehrere Audio-Dateien gleichzeitig verarbeiten")
                .font(.subheadline)
                .themedText(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Dateien auswählen") {
                // Implementation for multiple file selection
            }
            .buttonStyle(.borderedProminent)
        }
        .glassCard()
    }
    
    // MARK: - Helper Methods
    private func transcribeFile(_ url: URL) {
        transcriber.transcribeAudioFile(url: url) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let transcriptResult):
                    self.transcriptResult = transcriptResult
                    self.isShowingResults = true
                case .failure(let error):
                    // Handle error
                    print("Transcription error: \(error)")
                }
            }
        }
    }
}

// MARK: - Transcription Mode Card
struct TranscriptionModeCard: View {
    let mode: TranscriptionView.TranscriptionMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: mode.icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? AppTheme.accent : AppTheme.secondaryText)
                    .frame(width: 30)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title)
                        .font(.headline)
                        .themedText(.primary)
                    
                    Text(mode.description)
                        .font(.subheadline)
                        .themedText(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(AppTheme.accent)
                        .font(.title2)
                }
            }
            .padding(16)
            .background(
                isSelected ? AppTheme.accent.opacity(0.1) : AppTheme.secondaryBackground,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? AppTheme.accent : AppTheme.glassBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Document Picker
struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedFile: URL?
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                parent.selectedFile = url
            }
            parent.dismiss()
        }
    }
}

// MARK: - Transcription Results View
struct TranscriptionResultsView: View {
    let result: TranscriptResult
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Transkriptionsergebnis")
                            .font(.title2)
                            .fontWeight(.bold)
                            .themedText(.primary)
                        
                        HStack {
                            Text("Genauigkeit: \(Int(result.confidence * 100))%")
                                .font(.caption)
                                .themedText(.secondary)
                            
                            Spacer()
                            
                            Text("Sprache: \(result.language)")
                                .font(.caption)
                                .themedText(.secondary)
                        }
                    }
                    
                    // Transcript Text
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Transkript:")
                            .font(.headline)
                            .themedText(.primary)
                        
                        Text(result.text)
                            .font(.body)
                            .themedText(.primary)
                            .padding()
                            .background(AppTheme.secondaryBackground)
                            .cornerRadius(12)
                    }
                    
                    // Segments
                    if !result.segments.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Segmente:")
                                .font(.headline)
                                .themedText(.primary)
                            
                            ForEach(result.segments, id: \.id) { segment in
                                HStack {
                                    Text(formatTime(segment.start))
                                        .font(.caption)
                                        .themedText(.secondary)
                                        .frame(width: 60, alignment: .leading)
                                    
                                    Text(segment.text)
                                        .font(.body)
                                        .themedText(.primary)
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    
                    // Actions
                    HStack(spacing: 16) {
                        Button("Kopieren") {
                            UIPasteboard.general.string = result.text
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Teilen") {
                            // Implementation for sharing
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Speichern") {
                            // Implementation for saving
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }
            .themedBackground(.primary)
            .navigationTitle("Ergebnis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fertig") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#Preview {
    TranscriptionView()
        .environmentObject(ThemeManager())
}
*/
