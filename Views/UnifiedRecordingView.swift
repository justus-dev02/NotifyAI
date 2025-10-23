//
//  UnifiedRecordingView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI

struct UnifiedRecordingView: View {
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var recordingViewModel = RecordingViewModel()
    @State private var showConsent = false
    @State private var showProcessing = false
    @State private var selectedMode: RecordingMode = .realTime
    @State private var noteTitle = ""
    @State private var context = ""
    @State private var participants = ""
    @State private var location = ""
    
    enum RecordingMode: String, CaseIterable, Identifiable {
        case realTime = "realTime"
        case offline = "offline"
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .realTime: return "Echtzeit-Transkription"
            case .offline: return "Nur Audio-Aufnahme"
            }
        }
        
        var description: String {
            switch self {
            case .realTime: return "Live-Transkription während der Aufnahme"
            case .offline: return "Audio wird später transkribiert"
            }
        }
        
        var icon: String {
            switch self {
            case .realTime: return "waveform"
            case .offline: return "mic"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    recordingModeSection
                    detailsSection
                    startRecordingSection
                }
                .padding(24)
            }
            .themedBackground(.primary)
            .navigationTitle("Neue Aufnahme")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        // Dismiss view
                    }
                }
            }
            .sheet(isPresented: $showConsent) {
                ConsentSheet(
                    isPresented: $showConsent,
                    confirmed: .constant(true)
                ) { consent in
                    startRecording(with: consent)
                }
            }
            .sheet(isPresented: $showProcessing) {
                ProcessingView(
                    isPresented: $showProcessing,
                    note: recordingViewModel.note
                )
            }
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.accent)
            
            Text("Neue Aufnahme starten")
                .font(.title2)
                .fontWeight(.bold)
                .themedText(.primary)
            
            Text("Wähle den Aufnahmemodus und fülle die Details aus")
                .font(.body)
                .themedText(.secondary)
                .multilineTextAlignment(.center)
        }
        .glassCard()
    }
    
    // MARK: - Recording Mode Section
    private var recordingModeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aufnahmemodus")
                .font(.headline)
                .themedText(.primary)
            
            VStack(spacing: 12) {
                ForEach(RecordingMode.allCases) { mode in
                    RecordingModeCard(
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
    
    // MARK: - Details Section
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aufnahmedetails")
                .font(.headline)
                .themedText(.primary)
            
            VStack(spacing: 16) {
                // Title
                VStack(alignment: .leading, spacing: 8) {
                    Text("Titel")
                        .font(.subheadline)
                        .themedText(.primary)
                    TextField("z.B. Team Meeting, Vorlesung, etc.", text: $noteTitle)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kontext")
                        .font(.subheadline)
                        .themedText(.primary)
                    TextField("Kurze Beschreibung des Inhalts", text: $context, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Participants
                VStack(alignment: .leading, spacing: 8) {
                    Text("Teilnehmer (optional)")
                        .font(.subheadline)
                        .themedText(.primary)
                    TextField("z.B. Max, Lea, Team X", text: $participants)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Location
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ort (optional)")
                        .font(.subheadline)
                        .themedText(.primary)
                    TextField("z.B. Konferenzraum A, Online", text: $location)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .glassCard()
    }
    
    // MARK: - Start Recording Section
    private var startRecordingSection: some View {
        VStack(spacing: 16) {
            Button(action: { showConsent = true }) {
                HStack {
                    Image(systemName: "mic.fill")
                    Text("Aufnahme starten")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(AppTheme.accent)
                .cornerRadius(12)
            }
            .disabled(noteTitle.isEmpty)
            
            Text("Durch das Starten der Aufnahme bestätigst du, dass alle Teilnehmer einverstanden sind.")
                .font(.caption)
                .themedText(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Helper Methods
    private func startRecording(with consent: ConsentLog) {
        let title = noteTitle.isEmpty ? "Aufnahme \(Date().formatted(date: .abbreviated, time: .shortened))" : noteTitle
        
        var note = notesViewModel.createNew(title: title)
        note.location = location.isEmpty ? nil : location
        note.context = context.isEmpty ? nil : context
        
        if !participants.isEmpty {
            let participantNames = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            note.participants = participantNames.map { Participant(name: String($0), role: "") }
        }
        
        recordingViewModel.setupRecording(
            note: note,
            mode: selectedMode,
            consent: consent
        )
        
        Task {
            await recordingViewModel.startRecording()
            showProcessing = true
        }
    }
}

// MARK: - Recording Mode Card

struct RecordingModeCard: View {
    let mode: UnifiedRecordingView.RecordingMode
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

// MARK: - Recording View Model

class RecordingViewModel: ObservableObject {
    @Published var note: Note
    @Published var isRecording = false
    @Published var currentMode: UnifiedRecordingView.RecordingMode = .realTime
    
    private let serviceLocator = ServiceLocator.shared
    
    init() {
        self.note = Note(title: "Neue Aufnahme")
    }
    
    func setupRecording(
        note: Note,
        mode: UnifiedRecordingView.RecordingMode,
        consent: ConsentLog
    ) {
        self.note = note
        self.currentMode = mode
        self.note.consent = consent
    }
    
    func startRecording() async {
        isRecording = true
        
        switch currentMode {
        case .realTime:
            await startRealTimeRecording()
        case .offline:
            await startOfflineRecording()
        }
    }
    
    private func startRealTimeRecording() async {
        // Implementation for real-time transcription
        // This would use Apple Speech framework
    }
    
    private func startOfflineRecording() async {
        // Implementation for offline recording
        // This would just record audio without transcription
    }
}

// MARK: - Processing View

struct ProcessingView: View {
    @Binding var isPresented: Bool
    let note: Note
    @StateObject private var processingViewModel = ProcessingViewModel()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ProgressView(value: processingViewModel.progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
                    .padding()
                
                Text("Verarbeitung läuft...")
                    .font(.headline)
                    .themedText(.primary)
                
                Text(processingViewModel.currentStep)
                    .font(.subheadline)
                    .themedText(.secondary)
                
                Spacer()
                
                Button("In Hintergrund verarbeiten") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .onAppear {
                processingViewModel.startProcessing(note: note)
            }
        }
    }
}

class ProcessingViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentStep: String = "Vorbereitung..."
    
    func startProcessing(note: Note) {
        // Implementation for processing pipeline
        Task {
            await processNote(note)
        }
    }
    
    private func processNote(_ note: Note) async {
        // Simulate processing steps
        let steps = [
            "Audio wird verarbeitet...",
            "Transkription wird erstellt...",
            "Zusammenfassung wird generiert...",
            "Mindmap wird erstellt...",
            "Verarbeitung abgeschlossen"
        ]
        
        for (index, step) in steps.enumerated() {
            await MainActor.run {
                currentStep = step
                progress = Double(index + 1) / Double(steps.count)
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
}

#Preview {
    UnifiedRecordingView()
        .environmentObject(NotesViewModel())
        .environmentObject(ThemeManager())
}
