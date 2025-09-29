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

    init(note: Note) {
        _viewModel = StateObject(wrappedValue: RecorderViewModel(note: note))
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                Text(viewModel.liveText.isEmpty ? "Sprich – ich schreibe mit…" : viewModel.liveText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                TextField("Kontext hinzufügen…", text: $contextText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!viewModel.isRecording)
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
                    } else {
                        showConsent = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Aufnahme")
        .padding()
        .sheet(isPresented: $showConsent) {
            ConsentSheet(isPresented: $showConsent, confirmed: $consentConfirmed) { log in
                ConsentManager.shared.playStartBeep()
                viewModel.start(consent: log)
            }
        }
    }
}

#Preview {
    RecorderView(note: Note(title: "Demo"))
}
