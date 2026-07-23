//
//  DashboardView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var notesViewModel: NotesViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    searchArea
                    
                    sectionHeader(title: "Aktuelle Notizen")
                    
                    if vm.notes.isEmpty {
                        emptyNotesView
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(vm.notes) { note in
                                NavigationLink(destination: EnhancedNoteDetailView(note: note)) {
                                    EnhancedNoteCard(note: note)
                                        .padding(.horizontal, 20)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 32)
                    }
                }
                .padding(.top, 16)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.adaptiveBackground,
                        Color.indigo.opacity(0.05),
                        Color.purple.opacity(0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Zusammenfassungen")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        UnifiedRecordingView()
                            .environmentObject(notesViewModel)
                            .environmentObject(themeManager)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(Color.indigo)
                            Text("Aufnahme")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.adaptiveLabel)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    }
                }
            }
        }
    }

    private var searchArea: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.indigo)
                .font(.title3)
            
            TextField("Volltextsuche in Notizen & Transkripten…", text: $vm.query)
                .onChange(of: vm.query) { _ in
                    vm.performSearch()
                }
                .font(.body)
            
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    vm.performSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.indigo.opacity(0.2), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        .padding(.horizontal, 20)
    }

    private func sectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.adaptiveLabel)
            Spacer()
            
            Text("\(vm.notes.count) Notizen")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var emptyNotesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Color.indigo.opacity(0.6))
                .padding(.top, 40)
            
            Text("Keine Notizen gefunden")
                .font(.headline)
            
            Text("Starte eine neue Aufnahme oder erstelle eine Notiz.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
