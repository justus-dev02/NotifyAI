//
//  PipelineManager.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//  Updated for Robust End-to-End Processing & Proportional Speaker Overlap Mapping.
//

import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import AVFoundation

actor PipelineManager {
    static let backgroundTaskIdentifier = "com.justus.NotifyAI.pipeline"

    private let storage: StorageService
    private let diarizer: DiarizationService
    private let llm: LLMService
    private let highlight: HighlightService
    private let transcription: TranscriptionService
    private let search = SemanticSearchService.shared

    init(
        storage: StorageService,
        diarizer: DiarizationService,
        llm: LLMService,
        highlight: HighlightService,
        transcription: TranscriptionService
    ) {
        self.storage = storage
        self.diarizer = diarizer
        self.llm = llm
        self.highlight = highlight
        self.transcription = transcription
    }

    func registerBGTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { task in
            Task { await self.runPending(task: task as! BGProcessingTask) }
        }
    }

    func scheduleBG() {
        let req = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        req.requiresNetworkConnectivity = false
        req.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(req)
    }

    func enqueue(noteId: UUID, audio: URL) async {
        await run(noteId: noteId, audio: audio)
        scheduleBG()
    }

    private func update(_ noteId: UUID, stage: PipelineState.Stage, progress: Double, eta: Int?, msg: String?) async {
        await storage.updatePipeline(noteId: noteId) { s in
            s.stage = stage
            s.progress = progress
            s.etaSeconds = eta
            s.message = msg
        }
        await MainActor.run { NotificationCenter.default.post(name: .pipelineUpdated, object: noteId) }
    }

    private func run(noteId: UUID, audio: URL) async {
        do {
            await update(noteId, stage: .chunking, progress: 0.05, eta: nil, msg: "Audio wird vorbereitet…")

            // 1. Transcription (WhisperKit or Apple Speech)
            let backendName = transcription.backend.displayName
            await update(noteId, stage: .transcribing, progress: 0.25, eta: 10, msg: "Transkription (\(backendName))…")
            let segments = try await transcription.transcribe(audioURL: audio)

            // 2. Diarization & Speaker Turn Assignment
            await update(noteId, stage: .diarizing, progress: 0.50, eta: 6, msg: "Sprecherzuordnung…")
            let diar = try await diarizer.diarize(audio)
            let withSpeakers = mapSpeakers(segments, diar: diar)

            await storage.updateSegments(noteId: noteId, segments: withSpeakers)

            // 3. Summarization
            await update(noteId, stage: .summarizing, progress: 0.70, eta: 4, msg: "Zusammenfassung wird erstellt…")
            let fullText = withSpeakers.map { $0.text }.joined(separator: " ")
            var base = await llm.summarize(transcript: fullText)
            base.citations = withSpeakers.prefix(12).map(\.id)

            // 4. Role Summaries
            await update(noteId, stage: .roleSummaries, progress: 0.85, eta: 3, msg: "Rollenbasierte Auswertungen…")
            let roles = ["Sales", "Team", "Leadership"]
            var roleSummaries: [String: Summary] = [:]
            for r in roles {
                roleSummaries[r] = try await highlight.roleSummary(role: r, transcript: fullText, segments: withSpeakers)
            }

            // 5. Mindmap Generation
            await update(noteId, stage: .mindmap, progress: 0.92, eta: 2, msg: "Mindmap generieren…")
            let mind = try await highlight.makeMindmap(transcript: fullText)

            await storage.updateSummaries(noteId: noteId, summary: base, roleSummaries: roleSummaries, mindmap: mind)

            // 6. Semantic Search Indexing
            await update(noteId, stage: .indexing, progress: 0.96, eta: 1, msg: "Index aktualisieren…")
            let notes = await storage.loadAll()
            search.buildIndex(notes: notes)

            // 7. Completion
            await update(noteId, stage: .done, progress: 1.0, eta: 0, msg: "Fertig")
            notifyDone(noteId)
        } catch {
            await update(noteId, stage: .error, progress: 1.0, eta: nil, msg: error.localizedDescription)
        }
    }

    private func runPending(task: BGProcessingTask) async {
        defer { task.setTaskCompleted(success: true) }
        var cancelled = false
        task.expirationHandler = { cancelled = true }
        let pending = await storage.pendingNotes()
        for p in pending {
            if let audio = p.audioURL {
                await run(noteId: p.id, audio: audio)
            }
            if cancelled { break }
        }
    }

    private func notifyDone(_ id: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Aufbereitung abgeschlossen"
        content.body = "Deine Aufnahme ist jetzt vollständig zusammengefasst."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "done-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Assigns speaker IDs to transcript segments based on maximum time overlap
    private func mapSpeakers(
        _ segments: [TranscriptSegment],
        diar: [(start: TimeInterval, end: TimeInterval, speakerId: String)]
    ) -> [TranscriptSegment] {
        guard !diar.isEmpty else { return segments }

        return segments.map { seg in
            var s = seg
            var maxOverlap: TimeInterval = 0
            var matchedSpeaker: String? = nil

            for turn in diar {
                let overlapStart = max(seg.start, turn.start)
                let overlapEnd = min(seg.end, turn.end)
                let overlap = overlapEnd - overlapStart

                if overlap > maxOverlap {
                    maxOverlap = overlap
                    matchedSpeaker = turn.speakerId
                }
            }

            if let matchedSpeaker = matchedSpeaker, maxOverlap > 0.1 {
                s.speakerId = matchedSpeaker
            }
            return s
        }
    }
}

extension Notification.Name {
    static let pipelineUpdated = Notification.Name("pipelineUpdated")
    static let notesChanged = Notification.Name("notesChanged")
}
