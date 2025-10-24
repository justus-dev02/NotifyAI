//
//  RecorderView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct RecorderView: View {
    @StateObject private var viewModel: RecorderViewModel
    //@StateObject private var transcriptionViewModel = RealTimeTranscriptionViewModel()
    @State private var showConsent = false
    @State private var consentConfirmed = false
    @State private var contextText = ""
    @State private var showProcessing = false
    @State private var bookmarkName: String = ""
    @State private var isRealTimeTranscription = true
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    init(note: Note) {
        _viewModel = StateObject(wrappedValue: RecorderViewModel(note: note))
    }

    var body: some View {
        VStack(spacing: 24) {
            header
            transcriptionModeSelector
            //waveformArea
            contextSection
            footer
        }
        .padding(24)
        .themedBackground(.primary)
        .navigationTitle("Recorder")
        .sheet(isPresented: $showProcessing) {
            ProgressOverlayView(steps: ProcessingStep.build(from: viewModel.note.pipeline)) {
                showProcessing = false
            }
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(isPresented: $showConsent, confirmed: $consentConfirmed) { log in
                ConsentManager.shared.playStartBeep()
                Task {
                    await viewModel.start(consent: log)
                }
            }
        }
    }
}

private extension RecorderView {
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.isRecording ? "Läuft" : "Bereit")
                    .font(.title)
                    .bold()
                HStack(spacing: 12) {
                    Label(viewModel.timerDisplay, systemImage: "timer")
                    Label(viewModel.levelDisplay, systemImage: "waveform")
                    Label("Diarization: \(viewModel.diarizationStatus)", systemImage: "person.3.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: .constant(true)) {
                Label("Consent", systemImage: "hand.raised.fill")
            }
            .toggleStyle(.switch)
            .disabled(true)
        }
    }

    var transcriptionModeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transkriptionsmodus")
                .font(.headline)
                .themedText(.primary)
            
            HStack(spacing: 16) {
                Button(action: { isRealTimeTranscription = true }) {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Live-Transkription")
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        isRealTimeTranscription ? AppTheme.accent : AppTheme.secondaryBackground,
                        in: Capsule()
                    )
                    .foregroundColor(isRealTimeTranscription ? .white : AppTheme.primaryText)
                }
                .buttonStyle(.plain)
                
                Button(action: { isRealTimeTranscription = false }) {
                    HStack {
                        Image(systemName: "mic")
                        Text("Nur Audio")
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        !isRealTimeTranscription ? AppTheme.accent : AppTheme.secondaryBackground,
                        in: Capsule()
                    )
                    .foregroundColor(!isRealTimeTranscription ? .white : AppTheme.primaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard()
    }
    /*
    var waveformArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Live transcription display
                    if isRealTimeTranscription {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Live-Transkription")
                                    .font(.caption)
                                    .themedText(.secondary)
                                Spacer()
                                if transcriptionViewModel.confidence > 0 {
                                    Text("Genauigkeit: \(Int(transcriptionViewModel.confidence * 100))%")
                                        .font(.caption)
                                        .themedText(.secondary)
                                }
                            }
                            
                            Text(transcriptionViewModel.currentText.isEmpty ? "Sprich – ich schreibe mit…" : transcriptionViewModel.currentText)
                                .padding()
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        }
                    } else {
                        // Audio-only mode
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Audio-Aufnahme")
                                .font(.caption)
                                .themedText(.secondary)
                            
                            Text("Audio wird aufgezeichnet und später transkribiert")
                                .font(.body)
                                .themedText(.primary)
                                .padding()
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        }
                    }

                    ForEach(viewModel.bookmarks) { bookmark in
                        GlassCard {
                            HStack {
                                Label(bookmark.label, systemImage: bookmark.icon)
                                Spacer()
                                Text(bookmark.timecode)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                TextField("Marker hinzufügen (z. B. Entscheidung)", text: $bookmarkName)
                    .textFieldStyle(.roundedBorder)
                Button("Markieren") {
                    viewModel.addBookmark(label: bookmarkName)
                    bookmarkName = ""
                }
                .disabled(bookmarkName.isEmpty)
            }
        }
    }*/

    var contextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kontext & Teilnehmer")
                .font(.headline)
            TextField("Kontext hinzufügen…", text: $contextText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(!viewModel.isRecording)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(viewModel.note.participants) { participant in
                        Label(participant.name, systemImage: participant.avatarSymbol)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(participant.color.opacity(0.2), in: Capsule())
                    }
                    Button {
                        viewModel.addParticipant()
                    } label: {
                        Label("Teilnehmer", systemImage: "plus")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: Capsule())
                }
            }
        }
    }

    var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ForEach([1.0, 1.5, 2.0], id: \.self) { rate in
                    Button(String(format: "%.1fx", rate)) {}
                        .buttonStyle(.bordered)
                }
                Spacer()
                Menu {
                    Button("Kapitel setzen") {}
                    Button("Keyword") {}
                } label: {
                    Label("Kapitel", systemImage: "list.number")
                }
            }

            HStack(spacing: 16) {
                if viewModel.isRecording {
                    Button(viewModel.isPaused ? "Fortsetzen" : "Pause") {
                        viewModel.isPaused ? viewModel.resume() : viewModel.pause()
                    }
                    .buttonStyle(.bordered)
                }

                /*Button(viewModel.isRecording ? "Stop & Zusammenfassen" : "Aufnahme starten") {
                    if viewModel.isRecording {
                        if isRealTimeTranscription {
                            transcriptionViewModel.stopTranscription()
                        }
                        viewModel.stop()
                        showProcessing = true
                    } else {
                        if isRealTimeTranscription {
                            transcriptionViewModel.startTranscription()
                        }
                        showConsent = true
                    }
                }
                .buttonStyle(.borderedProminent)*/
            }
        }
    }
}

#Preview {
    RecorderView(note: Note(title: "Demo"))
}

