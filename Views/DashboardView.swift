//
//  DashboardView.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//  Updated for Apple Liquid Glass Design & Direct Import Hub Access.
//

import SwiftUI

struct DashboardView: View {
    @StateObject private var vm = DashboardViewModel()
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var notesViewModel: NotesViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    // Quick Stats & Engine Status Bar
                    statusPillsBar

                    // Hero Quick-Record Action Card
                    heroRecordCard

                    // Quick Actions Row (Import Hub & Templates)
                    quickActionsRow

                    // Recent Notes Section
                    recentNotesHeader

                    if vm.notes.isEmpty {
                        emptyStateCard
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(vm.notes.prefix(10)) { note in
                                NavigationLink(destination: EnhancedNoteDetailView(note: note)) {
                                    EnhancedNoteCard(note: note)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
            .liquidGlassBackground()
            .navigationTitle("NotifyAI")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        UnifiedRecordingView()
                            .environmentObject(notesViewModel)
                            .environmentObject(themeManager)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Aufnahme")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Color.indigo, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: Color.indigo.opacity(0.35), radius: 10, y: 4)
                    }
                }
            }
        }
    }

    // MARK: - Status Pills Bar

    private var statusPillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Engine Status Pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text(settingsViewModel.transcriptionBackend == .whisperKit ? "Whisper KI" : "Apple Speech")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))

                // On-Device Privacy Pill
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Color.indigo)
                    Text("100% Offline")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))

                // Notes Counter Pill
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.caption)
                        .foregroundStyle(Color.purple)
                    Text("\(vm.notes.count) Aufnahmen")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Hero Quick Record Card

    private var heroRecordCard: some View {
        NavigationLink {
            UnifiedRecordingView()
                .environmentObject(notesViewModel)
                .environmentObject(themeManager)
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.indigo.opacity(0.8), Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: Color.indigo.opacity(0.4), radius: 8, y: 3)

                    Image(systemName: "waveform.and.mic")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Gespräch aufnehmen")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.adaptiveLabel)

                    Text("Automatische KI-Zusammenfassung & Transkript")
                        .font(.caption)
                        .foregroundStyle(Color.adaptiveSecondaryLabel)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.adaptiveTertiaryLabel)
            }
            .padding(18)
            .liquidGlassCard(cornerRadius: 22, padding: 0)
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Actions Row

    private var quickActionsRow: some View {
        HStack(spacing: 14) {
            NavigationLink {
                ImportHubView()
                    .environmentObject(notesViewModel)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.headline)
                        .foregroundStyle(Color.indigo)
                    Text("PDF & OCR Scan")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                    Spacer()
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 18, padding: 0)
            }
            .buttonStyle(.plain)

            NavigationLink {
                TemplateLibraryView()
                    .environmentObject(notesViewModel)
                    .environmentObject(themeManager)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.headline)
                        .foregroundStyle(Color.purple)
                    Text("Vorlagen")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.adaptiveLabel)
                    Spacer()
                }
                .padding(14)
                .liquidGlassCard(cornerRadius: 18, padding: 0)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Recent Notes Header

    private var recentNotesHeader: some View {
        HStack {
            Text("Letzte Aufnahmen")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Color.adaptiveLabel)

            Spacer()

            NavigationLink {
                NotesListView()
                    .environmentObject(notesViewModel)
                    .environmentObject(settingsViewModel)
                    .environmentObject(themeManager)
            } label: {
                Text("Alle anzeigen")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.indigo)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: - Empty State Card

    private var emptyStateCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.indigo)
                .padding(.top, 16)

            VStack(spacing: 6) {
                Text("Noch keine Aufnahmen")
                    .font(.headline)
                    .foregroundStyle(Color.adaptiveLabel)

                Text("Tippe oben auf Aufnahme, um dein erstes Meeting oder Sprachmemos lokal analysieren zu lassen.")
                    .font(.caption)
                    .foregroundStyle(Color.adaptiveSecondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            NavigationLink {
                UnifiedRecordingView()
                    .environmentObject(notesViewModel)
                    .environmentObject(themeManager)
            } label: {
                Text("Jetzt aufnehmen")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.indigo, in: Capsule())
                    .shadow(color: Color.indigo.opacity(0.3), radius: 8, y: 3)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .liquidGlassCard(cornerRadius: 24, padding: 20)
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .environmentObject(ThemeManager())
        .environmentObject(NotesViewModel())
        .environmentObject(SettingsViewModel())
}
