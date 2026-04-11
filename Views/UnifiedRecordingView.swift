//
//  UnifiedRecordingView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import SwiftUI
import AVFoundation

struct UnifiedRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var themeManager: ThemeManager
    
    @StateObject private var vm = RecordingViewModel()
    
    @State private var showConsent = false
    @State private var hasConsent = false
    @State private var selectedMode: RecordingMode = .realTime
    @State private var noteTitle = ""
    @State private var context = ""
    @State private var participants = ""
    @State private var location = ""
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    enum ViewState {
        case setup
        case recording
    }
    
    @State private var currentState: ViewState = .setup
    
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
            Group {
                if currentState == .setup {
                    setupView
                } else {
                    activeRecordingView
                }
            }
            .themedBackground(.primary)
            .toolbar {
                if currentState == .setup {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Text("Neue Aufnahme")
                            .font(.headline)
                            .themedText(.primary)
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Abbrechen") {
                            dismiss()
                        }
                        .foregroundColor(.red)
                    }
                } else {
                    ToolbarItem(placement: .principal) {
                        Text("Aufnahme läuft")
                            .font(.headline)
                            .themedText(.primary)
                    }
                }
            }
            .sheet(isPresented: $showConsent) {
                ConsentSheet(
                    isPresented: $showConsent,
                    confirmed: $hasConsent
                ) { consent in
                    startRecordingSession(with: consent)
                }
            }
            .onChange(of: vm.shouldDismiss) { shouldDismiss in
                if shouldDismiss {
                    dismiss()
                }
            }
            .alert("Fehler", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    // MARK: - Setup View
    private var setupView: some View {
        ScrollView {
            VStack(spacing: 32) {
                headerSection
                
                VStack(alignment: .leading, spacing: 24) {
                    recordingModeSection
                    detailsSection
                }
                .padding(.horizontal, 24)
                
                VStack(spacing: 16) {
                    Button(action: {
                        showConsent = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "mic.fill")
                                .font(.headline)
                            Text("Aufnahme vorbereiten")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(noteTitle.isEmpty ? Color.gray.opacity(0.3) : AppTheme.accent)
                        .cornerRadius(16)
                        .shadow(color: noteTitle.isEmpty ? Color.clear : AppTheme.accent.opacity(0.3), radius: 10, y: 5)
                    }
                    .disabled(noteTitle.isEmpty)
                    
                    Text("Nach der Konfiguration folgt die Zustimmung der Teilnehmer.")
                        .font(.caption)
                        .themedText(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 24)
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
            }
            
            Text("Bereit für die Aufnahme?")
                .font(.title2.bold())
                .themedText(.primary)
            
            Text("Konfiguriere deine Session")
                .font(.subheadline)
                .themedText(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var recordingModeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modus")
                .font(.headline)
                .themedText(.primary)
            
            HStack(spacing: 12) {
                ForEach(RecordingMode.allCases) { mode in
                    Button(action: { selectedMode = mode }) {
                        VStack(spacing: 8) {
                            Image(systemName: mode.icon)
                                .font(.title2)
                            Text(mode.title)
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            selectedMode == mode ? AppTheme.accent.opacity(0.1) : AppTheme.secondaryBackground,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(selectedMode == mode ? AppTheme.accent : Color.clear, lineWidth: 2)
                        )
                        .foregroundColor(selectedMode == mode ? AppTheme.accent : AppTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Details")
                .font(.headline)
                .themedText(.primary)
            
            VStack(spacing: 16) {
                CustomTextField(title: "Titel", placeholder: "Thema des Meetings", text: $noteTitle)
                CustomTextField(title: "Teilnehmer", placeholder: "Wer ist dabei?", text: $participants)
                CustomTextField(title: "Ort", placeholder: "Raum oder Online", text: $location)
            }
        }
        .padding(20)
        .glassCard()
    }
    
    // MARK: - Active Recording View
    private var activeRecordingView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Timer and Title
            VStack(spacing: 8) {
                Text(vm.timerString)
                    .font(.system(size: 64, weight: .thin, design: .monospaced))
                    .themedText(.primary)
                
                Text(noteTitle)
                    .font(.headline)
                    .themedText(.secondary)
            }
            
            // Waveform Visualizer
            WaveformView(amplitudes: vm.amplitudes)
                .frame(height: 120)
                .padding(.horizontal)
            
            // Live Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.liveTranscript.isEmpty ? "Warte auf Sprache..." : vm.liveTranscript)
                        .font(.body)
                        .themedText(vm.liveTranscript.isEmpty ? .secondary : .primary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .frame(maxHeight: 200)
                .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .onChange(of: vm.liveTranscript) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            
            Spacer()
            
            // Controls
            HStack(spacing: 40) {
                // Pause/Resume
                Button(action: {
                    if vm.isPaused {
                        vm.resumeRecording()
                    } else {
                        vm.pauseRecording()
                    }
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.title)
                        Text(vm.isPaused ? "Fortsetzen" : "Pause")
                            .font(.caption)
                    }
                    .foregroundColor(AppTheme.accent)
                    .frame(width: 80)
                }
                
                // Stop
                Button(action: {
                    Task {
                        await vm.stopRecording()
                    }
                }) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(.red)
                                .frame(width: 64, height: 64)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white)
                                .frame(width: 24, height: 24)
                        }
                        Text("Beenden")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                    }
                }
                
                // Info/Cancel (optional)
                Button(action: { /* Add metadata during recording */ }) {
                    VStack(spacing: 8) {
                        Image(systemName: "tag.fill")
                            .font(.title)
                        Text("Markieren")
                            .font(.caption)
                    }
                    .foregroundColor(AppTheme.secondaryText)
                    .frame(width: 80)
                }
            }
            .padding(.bottom, 40)
        }
    }
    
    // MARK: - Actions
    private func startRecordingSession(with consent: ConsentLog) {
        let title = noteTitle.isEmpty ? "Aufnahme \(Date().formatted(date: .abbreviated, time: .shortened))" : noteTitle
        
        var note = Note(title: title)
        note.location = location.isEmpty ? nil : location
        note.consent = consent
        
        if !participants.isEmpty {
            let names = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            note.participants = names.map { Participant(name: String($0), role: "") }
        }
        
        vm.setup(note: note, mode: selectedMode, notesViewModel: notesViewModel)
        
        // Request microphone permission before starting
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.errorMessage = "Mikrofon-Zugriff wurde verweigert. Bitte erlaube den Zugriff in den Einstellungen."
                    self.showErrorAlert = true
                    return
                }
                withAnimation {
                    currentState = .recording
                }
                vm.startRecording()

                // If real-time mode, try to start WhisperBackend streaming stub
                if selectedMode == .realTime {
                    Task {
                        do {
                            // Using the shared WhisperBackend from Services/Backends/WhisperBackend.swift
                            try await WhisperBackend.shared.start { text, _, _ in
                                // Hook for future partial/final transcripts from Whisper
                                // e.g., vm.liveTranscript = text
                            }
                        } catch {
                            print("WhisperBackend start failed: \(error)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Waveform View
struct WaveformView: View {
    let amplitudes: [Float]
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<amplitudes.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.accent.gradient)
                    .frame(width: 3, height: max(6, CGFloat(amplitudes[index]) * 150))
            }
        }
    }
}

// MARK: - Custom UI Components
struct CustomTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .themedText(.secondary)
            
            TextField(placeholder, text: $text)
                .padding(16)
                .themedText(.primary)
                .tint(AppTheme.accent)
                .background(AppTheme.secondaryBackground.opacity(0.8))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.accent.opacity(0.3), lineWidth: 1)
                )
                .disableAutocorrection(true)
        }
    }
}

// MARK: - Recording ViewModel
@MainActor
class RecordingViewModel: ObservableObject {
    @Published var amplitudes: [Float] = Array(repeating: 0.1, count: 40)
    @Published var timerString = "00:00"
    @Published var liveTranscript = ""
    @Published var isPaused = false
    @Published var shouldDismiss = false
    
    private var note: Note?
    private var mode: UnifiedRecordingView.RecordingMode = .realTime
    private var notesViewModel: NotesViewModel?
    
    private let recorder = RecordingService()
    private var timer: Timer?
    private var startTime: Date?
    private var accumulatedTime: TimeInterval = 0
    
    func setup(note: Note, mode: UnifiedRecordingView.RecordingMode, notesViewModel: NotesViewModel) {
        self.note = note
        self.mode = mode
        self.notesViewModel = notesViewModel
    }
    
    func startRecording() {
        guard let note = note else { return }
        
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(note.id).m4a")
        self.note?.audioURL = fileURL
        
        recorder.amplitudeCallback = { [weak self] amp in
            self?.updateAmplitudes(amp)
        }
        
        do {
            try recorder.start(to: fileURL)
            startTime = Date()
            startTimer()
            
            if mode == .realTime {
                startLiveTranscription()
            }
        } catch {
            print("Recording start failed: \(error)")
        }
    }
    
    func pauseRecording() {
        recorder.pause()
        isPaused = true
        timer?.invalidate()
        if let start = startTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
    }
    
    func resumeRecording() {
        recorder.resume()
        isPaused = false
        startTime = Date()
        startTimer()
    }
    
    func stopRecording() async {
        let duration = recorder.stop()
        timer?.invalidate()
        
        if var finalNote = note {
            finalNote.duration = duration
            // Here you would normally save to disk or storage
            // For now we add it to the view model
            // Persist the note via StorageService and notify observers to refresh lists
            await ServiceLocator.shared.storage.save(finalNote)
            NotificationCenter.default.post(name: .notesChanged, object: nil)
            
            // Start pipeline processing
            await ServiceLocator.shared.pipeline.enqueue(noteId: finalNote.id, audio: finalNote.audioURL!)
        }
        
        shouldDismiss = true
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let total = self.accumulatedTime + Date().timeIntervalSince(start)
            let mins = Int(total) / 60
            let secs = Int(total) % 60
            self.timerString = String(format: "%02d:%02d", mins, secs)
        }
    }
    
    private func updateAmplitudes(_ amp: Float) {
        amplitudes.removeFirst()
        // Simple scaling for visualization
        amplitudes.append(min(1.0, max(0.1, amp * 5)))
    }
    
    private func startLiveTranscription() {
        // This is a placeholder for actual SFSpeech integration
        // In a real app, you would bridge recorder.bufferConsumer to SpeechTranscriber
        Task {
            // Simulated live transcription
            let words = ["Willkommen", "beim", "Meeting", "heute.", "Wir", "besprechen", "die", "neue", "App", "Struktur.", "Die", "KI", "hilft", "beim", "Mitschreiben."]
            for word in words {
                if isPaused { continue }
                try? await Task.sleep(nanoseconds: 800 * 1_000_000)
                if !isPaused {
                    self.liveTranscript += word + " "
                }
            }
        }
    }
}
