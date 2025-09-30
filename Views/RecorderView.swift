//
//  RecorderView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct RecorderView: View {
    @StateObject private var viewModel: RecorderViewModel
    @State private var showConsent = false
    @State private var consentConfirmed = false
    @State private var contextText = ""
    @State private var showProcessing = false
    @State private var bookmarkName: String = ""

    init(note: Note) {
        _viewModel = StateObject(wrappedValue: RecorderViewModel(note: note))
    }

    var body: some View {
        VStack(spacing: 24) {
            header
            waveformArea
            contextSection
            footer
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(hex: "#EEF2FF") ?? .blue.opacity(0.1), .white], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
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

    var waveformArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.liveText.isEmpty ? "Sprich – ich schreibe mit…" : viewModel.liveText)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))

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
    }

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

                Button(viewModel.isRecording ? "Stop & Zusammenfassen" : "Aufnahme starten") {
                    if viewModel.isRecording {
                        viewModel.stop()
                        showProcessing = true
                    } else {
                        showConsent = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview {
    RecorderView(note: Note(title: "Demo"))
}

