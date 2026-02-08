//
//  RecorderView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

// NotifyAI/Views/RecorderView.swift
import SwiftUI

struct RecorderView: View {
    @StateObject private var viewModel: RecorderViewModel
    @State private var showConsent = false
    @State private var consentConfirmed = false // Wird vom ConsentSheet gesetzt
    @State private var contextText: String // Use local state, sync with ViewModel's note
    @State private var showProcessing = false
    @State private var bookmarkName: String = ""
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager

    init(note: Note) {
        _viewModel = StateObject(wrappedValue: RecorderViewModel(note: note))
        // Initialize local state from the note passed to the ViewModel
        _contextText = State(initialValue: note.context ?? "")
    }

    var body: some View {
        VStack(spacing: 24) {
            header
            liveTranscriptionArea // Neuer Bereich für Live-Text
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
                    // Update note details from local state before starting
                    viewModel.note.context = contextText.isEmpty ? nil : contextText
                    // You might add participant/location updates here too if needed
                    await viewModel.start(consent: log)
                }
            }
        }
        .onChange(of: viewModel.note.pipeline.stage) { _, newStage in // Correct signature for iOS 15+
             if newStage != .none && newStage != .done && newStage != .error && !viewModel.isRecording {
                 showProcessing = true
             } else {
                 showProcessing = false
             }
         }
         // Sync local contextText changes back to the ViewModel's note
         .onChange(of: contextText) { _, newValue in
              viewModel.note.context = newValue.isEmpty ? nil : newValue
         }
         // Sync changes from ViewModel's note.context back to local state (e.g., if loaded)
         .onReceive(viewModel.$note) { updatedNote in
              if contextText != (updatedNote.context ?? "") {
                   contextText = updatedNote.context ?? ""
              }
         }
    }
}

private extension RecorderView {
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.isRecording ? (viewModel.isPaused ? "Pausiert" : "Nimmt auf...") : "Bereit")
                    .font(.title)
                    .bold()
                    .foregroundColor(viewModel.isRecording ? (viewModel.isPaused ? .orange : .red) : AppTheme.primaryText) // Use theme color
                HStack(spacing: 12) {
                    // Corrected Access: Use explicit Label initializers
                    Label {
                        Text(viewModel.timerDisplay)
                    } icon: {
                        Image(systemName: "timer")
                    }
                    Label {
                        Text(viewModel.levelDisplay)
                    } icon: {
                        Image(systemName: "waveform")
                    }
                    Label {
                        Text("Diarization: \(viewModel.diarizationStatus)")
                    } icon: {
                        Image(systemName: "person.3.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Live", isOn: $viewModel.isRealTimeTranscriptionEnabled)
                 .labelsHidden()
                 .disabled(viewModel.isRecording)
        }
    }

     var liveTranscriptionArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.isRealTimeTranscriptionEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            // Corrected Access: Use viewModel.backendDisplayName
                            Text("Live-Transkription (\(viewModel.backendDisplayName))")
                                .font(.caption)
                                .themedText(.secondary)

                            Text(viewModel.liveText.isEmpty && viewModel.isRecording ? "Sprich – ich schreibe mit…" : viewModel.liveText)
                                .font(.body)
                                .themedText(.primary)
                                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                                .padding()
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.glassBorder.opacity(0.1), lineWidth: 1)) // Use theme color
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Audio-Aufnahme (Offline-Transkription)")
                                .font(.caption)
                                .themedText(.secondary)

                            Text("Audio wird aufgezeichnet und nach dem Stoppen verarbeitet.")
                                .font(.body)
                                .themedText(.primary)
                                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                                .padding()
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.glassBorder.opacity(0.1), lineWidth: 1)) // Use theme color
                        }
                    }

                     if !viewModel.bookmarks.isEmpty {
                         Text("Marker")
                             .font(.caption)
                             .themedText(.secondary)
                         ForEach(viewModel.bookmarks) { bookmark in
                             GlassCard {
                                 HStack {
                                     Label(bookmark.label, systemImage: bookmark.icon)
                                     Spacer()
                                     Text(bookmark.timecode)
                                         .font(.caption)
                                 }
                                 if let context = bookmark.context, !context.isEmpty {
                                     Text("Kontext: \"...\(context)\"")
                                         .font(.caption2)
                                         .foregroundStyle(.secondary)
                                         .italic()
                                         .lineLimit(1)
                                 }
                             }
                         }
                    }
                }
            }
             .frame(maxHeight: 300)

             if viewModel.isRecording {
                HStack(spacing: 12) {
                    TextField("Marker hinzufügen (z. B. Entscheidung)", text: $bookmarkName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        // Corrected Access: Use viewModel directly
                        viewModel.addBookmark(label: bookmarkName.isEmpty ? "Marker" : bookmarkName)
                        bookmarkName = ""
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                         Image(systemName: "bookmark.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
         .glassCard()
    }

    var contextSection: some View {
         VStack(alignment: .leading, spacing: 12) {
             Text("Kontext & Teilnehmer")
                 .font(.headline)
                 .themedText(.primary) // Apply theme
             // Use local state contextText Binding
             TextField("Kontext hinzufügen…", text: $contextText, axis: .vertical)
                 .lineLimit(1...4)
                 .textFieldStyle(.roundedBorder)

             ScrollView(.horizontal, showsIndicators: false) {
                 HStack {
                     // Iterate over the note participants non-binding
                     ForEach(viewModel.note.participants, id: \.id) { participant in
                         Label(participant.name, systemImage: participant.avatarSymbol)
                             .padding(.horizontal, 12)
                             .padding(.vertical, 6)
                             .background(participant.color.opacity(0.2), in: Capsule())
                             .themedText(.primary) // Apply theme
                             .onTapGesture {
                                 print("Edit participant \(participant.name)")
                             }
                     }
                     Button {
                         // Corrected Access: Use viewModel directly
                         viewModel.addParticipant()
                     } label: {
                         Label("Hinzufügen", systemImage: "plus")
                     }
                     .padding(.horizontal, 12)
                     .padding(.vertical, 6)
                     .background(Color.secondary.opacity(0.1), in: Capsule())
                     .buttonStyle(.plain)
                     .themedText(.secondary) // Apply theme
                 }
             }
         }
         .glassCard()
     }

    var footer: some View {
         VStack(spacing: 12) {
             HStack(spacing: 16) {
                 if viewModel.isRecording {
                     Button {
                         // Corrected Access: Use viewModel directly
                         viewModel.isPaused ? viewModel.resume() : viewModel.pause()
                     } label: {
                         Label(viewModel.isPaused ? "Fortsetzen" : "Pause", systemImage: viewModel.isPaused ? "play.fill" : "pause.fill")
                     }
                     .buttonStyle(.bordered)
                     .tint(viewModel.isPaused ? .blue : .orange)

                     Button {
                         // Corrected Access: Use viewModel directly
                         viewModel.stop()
                         // Corrected Access: Use viewModel.backendDisplayName
                         if !viewModel.isRealTimeTranscriptionEnabled || viewModel.backendDisplayName != TranscriptionService.Backend.appleSpeech.displayName {
                              showProcessing = true
                         }
                     } label: {
                         Label("Stop & Verarbeiten", systemImage: "stop.fill")
                     }
                     .buttonStyle(.borderedProminent)
                     .tint(.red)
                 } else {
                      Button {
                          consentConfirmed = false
                          showConsent = true
                      } label: {
                          Label("Aufnahme starten", systemImage: "mic.fill")
                      }
                      .buttonStyle(.borderedProminent)
                      .tint(.green)
                 }
             }
             .frame(maxWidth: .infinity)
         }
     }
}

// Preview needs necessary EnvironmentObjects
#Preview {
     NavigationView {
         RecorderView(note: SampleDataFactory.makeSampleNotes().first ?? Note(title: "Preview Note"))
             .environmentObject(AppState())
             .environmentObject(ThemeManager())
             .environmentObject(ServiceLocator.shared) // Inject ServiceLocator for ViewModel
     }
}

