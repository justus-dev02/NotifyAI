//
//  UnifiedRecordingView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated for Consolidated CoreAudio & Live STT Pipeline.
//

import SwiftUI
import AVFoundation

struct UnifiedRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var themeManager: ThemeManager

    @StateObject private var vm: RecorderViewModel

    @State private var showConsent = false
    @State private var hasConsent = false
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

    init(note: Note = Note(title: "Neue Aufnahme"), prefilledContext: String = "") {
        _vm = StateObject(wrappedValue: RecorderViewModel(note: note))
        _noteTitle = State(initialValue: note.title == "Neue Notiz" || note.title == "Neue Aufnahme" ? "" : note.title)
        _context = State(initialValue: prefilledContext)
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
            .liquidGlassBackground()
            .toolbar {
                if currentState == .setup {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Text("Neue Aufnahme")
                            .font(.headline)
                            .foregroundStyle(Color.adaptiveLabel)
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
                            .foregroundStyle(Color.adaptiveLabel)
                    }
                }
            }
            .sheet(isPresented: $showConsent) {
                ConsentSheet(
                    isPresented: $showConsent,
                    confirmed: $hasConsent,
                    participantsInput: participants,
                    locationInput: location
                ) { consent in
                    startRecordingSession(with: consent)
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
            VStack(spacing: 24) {
                headerSection

                VStack(alignment: .leading, spacing: 16) {
                    Text("Details zur Aufnahme")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.adaptiveLabel)

                    VStack(spacing: 14) {
                        CustomTextField(title: "Thema / Titel", placeholder: "z.B. Team Update & Planning", text: $noteTitle)
                        CustomTextField(title: "Kontext", placeholder: "z.B. Strategie für Q3", text: $context)
                        CustomTextField(title: "Teilnehmer", placeholder: "z.B. Max, Anna, Jonas", text: $participants)
                        CustomTextField(title: "Ort", placeholder: "z.B. Raum 302 oder Online", text: $location)
                    }
                }
                .padding(.horizontal, 20)

                VStack(spacing: 12) {
                    Button(action: {
                        showConsent = true
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                                .font(.headline)
                            Text("Aufnahme vorbereiten")
                                .font(.headline)
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            noteTitle.trimmingCharacters(in: .whitespaces).isEmpty
                            ? LinearGradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .shadow(color: noteTitle.trimmingCharacters(in: .whitespaces).isEmpty ? Color.clear : Color.indigo.opacity(0.35), radius: 10, y: 5)
                    }
                    .disabled(noteTitle.trimmingCharacters(in: .whitespaces).isEmpty)

                    Text(noteTitle.trimmingCharacters(in: .whitespaces).isEmpty ? "Bitte trage mindestens einen Titel ein, um fortzufahren." : "Bereit! Klicke zum Bestätigen der Teilnehmer-Zustimmung.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .padding(.vertical, 16)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Color.indigo)
            }

            Text("Neue Audio-Aufnahme")
                .font(.title2.bold())
                .foregroundStyle(Color.adaptiveLabel)

            Text("100% Lokale Transkription & KI-Auswertung")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active Recording View
    private var activeRecordingView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Timer and Title
            VStack(spacing: 8) {
                Text(vm.timerDisplay)
                    .font(.system(size: 60, weight: .light, design: .monospaced))
                    .foregroundStyle(Color.adaptiveLabel)

                Text(vm.note.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Waveform Visualizer
            WaveformView(amplitudes: vm.amplitudes)
                .frame(height: 100)
                .padding(.horizontal)

            // Live Transcript Box
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.liveText.isEmpty ? "Warte auf Spracheingabe… (Spreche jetzt)" : vm.liveText)
                        .font(.body)
                        .foregroundStyle(vm.liveText.isEmpty ? .secondary : Color.adaptiveLabel)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("bottom")
                }
                .frame(maxHeight: 220)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 20)
                .onChange(of: vm.liveText) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Spacer()

            // Controls
            HStack(spacing: 32) {
                // Pause/Resume
                Button(action: {
                    if vm.isPaused {
                        vm.resume()
                    } else {
                        vm.pause()
                    }
                }) {
                    VStack(spacing: 6) {
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.title)
                        Text(vm.isPaused ? "Fortsetzen" : "Pause")
                            .font(.caption)
                    }
                    .foregroundColor(Color.indigo)
                    .frame(width: 72)
                }

                // Stop & Process
                Button(action: {
                    vm.stop()
                    Task {
                        await notesViewModel.load()
                        dismiss()
                    }
                }) {
                    VStack(spacing: 6) {
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

                // Live Bookmark Button
                Button(action: {
                    vm.addBookmark(label: "Wichtiger Punkt")
                }) {
                    VStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.title)
                        Text("Highlight")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                    .frame(width: 72)
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Actions
    private func startRecordingSession(with consent: ConsentLog) {
        let title = noteTitle.isEmpty ? "Aufnahme \(Date().formatted(date: .abbreviated, time: .shortened))" : noteTitle

        vm.note.title = title
        vm.note.location = location.isEmpty ? nil : location
        vm.note.context = context.isEmpty ? nil : context

        if !participants.isEmpty {
            let names = participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            vm.note.participants = names.map { Participant(name: String($0), role: "") }
        }

        Task {
            let granted = await ServiceLocator.shared.audioSession.requestPermission()
            if granted {
                self.currentState = .recording
                await self.vm.start(consent: consent)
            } else {
                self.errorMessage = "Mikrofon-Zugriff wurde verweigert. Bitte erlaube den Zugriff in den iOS-Einstellungen."
                self.showErrorAlert = true
            }
        }
    }
}

// MARK: - Helper Views
struct CustomTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
    }
}

struct WaveformView: View {
    let amplitudes: [Float]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<amplitudes.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.purple],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: max(4, CGFloat(amplitudes[index]) * 100))
            }
        }
    }
}

#Preview {
    UnifiedRecordingView()
        .environmentObject(NotesViewModel())
        .environmentObject(ThemeManager())
}
