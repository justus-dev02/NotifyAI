//
//  RecorderView.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import SwiftUI

struct RecorderView: View {
    @StateObject private var vm = RecorderViewModel()
    @State private var contextText = ""
    @Binding var note: Note

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                Text(vm.currentText.isEmpty ? "Sprich – ich schreibe mit…" : vm.currentText)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Kontext hinzufügen…", text: $contextText, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { ServiceLocator.shared.pipelineAddContext(contextText, for: note.id); contextText = "" }
            }
            Button(vm.isRecording ? "Stop & Zusammenfassen" : "Aufnahme starten") {
                if vm.isRecording {
                    vm.stopAndSummarize(into: &note)
                } else {
                    vm.start()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Aufnahme")
        .padding()
    }
}
