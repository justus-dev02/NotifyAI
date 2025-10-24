//
//  TranscriptionSettingsView.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//
/*
import SwiftUI

struct TranscriptionSettingsView: View {
    @StateObject private var transcriber = SpeechTranscriber.shared
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedLanguage = "de-DE"
    @State private var enableRealTime = true
    @State private var enableConfidenceDisplay = true
    @State private var enableAutoPunctuation = true
    @State private var enableSpeakerDiarization = false
    @State private var testPhrase = "Das ist ein Test der Spracherkennung."
    @State private var isTesting = false
    @State private var testResult = ""
    
    private let supportedLanguages = [
        ("de-DE", "Deutsch"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("fr-FR", "Français"),
        ("es-ES", "Español"),
        ("it-IT", "Italiano"),
        ("pt-PT", "Português"),
        ("nl-NL", "Nederlands")
    ]
    
    var body: some View {
        NavigationStack {
            Form {
                // Authorization Status
                Section {
                    HStack {
                        Image(systemName: transcriber.isAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(transcriber.isAuthorized ? .green : .orange)
                        
                        VStack(alignment: .leading) {
                            Text(transcriber.isAuthorized ? "Berechtigung erteilt" : "Berechtigung erforderlich")
                                .font(.headline)
                            Text(transcriber.isAuthorized ? "Spracherkennung ist aktiviert" : "Aktivieren Sie die Spracherkennung in den Einstellungen")
                                .font(.caption)
                                .themedText(.secondary)
                        }
                        
                        Spacer()
                        
                        if !transcriber.isAuthorized {
                            Button("Einstellungen") {
                                openSettings()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Status")
                }
                
                // Language Settings
                Section {
                    Picker("Sprache", selection: $selectedLanguage) {
                        ForEach(supportedLanguages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Text("Die Spracherkennung wird für die ausgewählte Sprache optimiert.")
                        .font(.caption)
                        .themedText(.secondary)
                } header: {
                    Text("Sprache")
                } footer: {
                    Text("Weitere Sprachen können in den iOS-Einstellungen hinzugefügt werden.")
                }
                
                // Real-time Settings
                Section {
                    Toggle("Echtzeit-Transkription", isOn: $enableRealTime)
                    
                    Toggle("Genauigkeitsanzeige", isOn: $enableConfidenceDisplay)
                        .disabled(!enableRealTime)
                    
                    Toggle("Automatische Zeichensetzung", isOn: $enableAutoPunctuation)
                        .disabled(!enableRealTime)
                    
                    Toggle("Sprechererkennung", isOn: $enableSpeakerDiarization)
                        .disabled(!enableRealTime)
                } header: {
                    Text("Echtzeit-Einstellungen")
                } footer: {
                    Text("Echtzeit-Transkription ermöglicht die sofortige Umwandlung von Sprache in Text während der Aufnahme.")
                }
                
                // Test Section
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Test-Phrase")
                            .font(.headline)
                            .themedText(.primary)
                        
                        TextField("Test-Phrase eingeben", text: $testPhrase, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        
                        HStack {
                            Button("Test starten") {
                                startTest()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isTesting || !transcriber.isAuthorized)
                            
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        
                        if !testResult.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ergebnis:")
                                    .font(.caption)
                                    .themedText(.secondary)
                                
                                Text(testResult)
                                    .font(.body)
                                    .themedText(.primary)
                                    .padding()
                                    .background(AppTheme.secondaryBackground)
                                    .cornerRadius(8)
                            }
                        }
                    }
                } header: {
                    Text("Test")
                } footer: {
                    Text("Testen Sie die Spracherkennung mit einer eigenen Phrase.")
                }
                
                // Advanced Settings
                Section {
                    NavigationLink("Erweiterte Einstellungen") {
                        AdvancedTranscriptionSettingsView()
                    }
                } header: {
                    Text("Erweitert")
                }
                
                // Usage Statistics
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Transkriptionen heute")
                            Spacer()
                            Text("0")
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            Text("Gesamt transkribiert")
                            Spacer()
                            Text("0 Minuten")
                                .fontWeight(.semibold)
                        }
                        
                        HStack {
                            Text("Durchschnittliche Genauigkeit")
                            Spacer()
                            Text("--%")
                                .fontWeight(.semibold)
                        }
                    }
                } header: {
                    Text("Statistiken")
                } footer: {
                    Text("Statistiken werden lokal gespeichert und nicht übertragen.")
                }
            }
            .navigationTitle("Spracherkennung")
            .navigationBarTitleDisplayMode(.large)
        }
    }
    
    private func openSettings() {
        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsUrl)
        }
    }
    
    private func startTest() {
        guard !testPhrase.isEmpty else { return }
        
        isTesting = true
        testResult = ""
        
        // Simulate transcription test
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            testResult = "Test erfolgreich: '\(testPhrase)' wurde erkannt."
            isTesting = false
        }
    }
}

// MARK: - Advanced Settings View
struct AdvancedTranscriptionSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var enableNoiseReduction = true
    @State private var enableVoiceActivityDetection = true
    @State private var sensitivityLevel: Double = 0.5
    @State private var maxRecordingDuration: Double = 60
    @State private var enableAutoStop = true
    @State private var enableBackgroundProcessing = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Rauschunterdrückung", isOn: $enableNoiseReduction)
                
                Toggle("Sprachaktivitätserkennung", isOn: $enableVoiceActivityDetection)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Empfindlichkeit: \(Int(sensitivityLevel * 100))%")
                        .font(.headline)
                        .themedText(.primary)
                    
                    Slider(value: $sensitivityLevel, in: 0...1, step: 0.1)
                        .tint(AppTheme.accent)
                    
                    Text("Niedrige Werte = weniger empfindlich, hohe Werte = sehr empfindlich")
                        .font(.caption)
                        .themedText(.secondary)
                }
            } header: {
                Text("Audio-Verarbeitung")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Maximale Aufnahmedauer: \(Int(maxRecordingDuration)) Minuten")
                        .font(.headline)
                        .themedText(.primary)
                    
                    Slider(value: $maxRecordingDuration, in: 1...120, step: 1)
                        .tint(AppTheme.accent)
                }
                
                Toggle("Automatisches Stoppen", isOn: $enableAutoStop)
                
                Toggle("Hintergrundverarbeitung", isOn: $enableBackgroundProcessing)
            } header: {
                Text("Aufnahme-Einstellungen")
            } footer: {
                Text("Hintergrundverarbeitung ermöglicht die Transkription auch wenn die App nicht aktiv ist.")
            }
            
            Section {
                Button("Alle Einstellungen zurücksetzen") {
                    resetToDefaults()
                }
                .foregroundColor(.red)
            } header: {
                Text("Zurücksetzen")
            }
        }
        .navigationTitle("Erweiterte Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func resetToDefaults() {
        enableNoiseReduction = true
        enableVoiceActivityDetection = true
        sensitivityLevel = 0.5
        maxRecordingDuration = 60
        enableAutoStop = true
        enableBackgroundProcessing = false
    }
}

#Preview {
    TranscriptionSettingsView()
        .environmentObject(ThemeManager())
}
*/
