//
//  PipelineManager.swift
//  NotifyAI
//
//  Created by Justus on 29.09.25.
//

import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import AVFoundation

actor PipelineManager {
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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.your.app.pipeline", using: nil) { task in
            Task { await self.runPending(task: task as! BGProcessingTask) }
        }
    }

    func scheduleBG() {
        let req = BGProcessingTaskRequest(identifier: "com.your.app.pipeline")
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

    private func chunks(for audio: URL, targetSec: Double = 300) async -> [URL] {
        return [audio]
    }

    private func run(noteId: UUID, audio: URL) async {
        do {
            await update(noteId, stage: .chunking, progress: 0.05, eta: nil, msg: "Audio wird vorbereitet…")
            let parts = await chunks(for: audio)

            var allSegments: [TranscriptSegment] = []
            var c = 0
            for part in parts {
                c += 1
                let p = Double(c) / Double(parts.count)
                let backendName = transcription.backend.displayName
                await update(noteId, stage: .transcribing, progress: 0.1 + 0.6 * p, eta: estimateETA(parts.count - c, perChunk: 30), msg: "Transkription (\(backendName))…")

                let segmentsPart = try await transcription.transcribe(audioURL: part)
                allSegments.append(contentsOf: segmentsPart)
            }

            await update(noteId, stage: .diarizing, progress: 0.72, eta: 15, msg: "Sprecherzuordnung…")
            let diar = try await diarizer.diarize(audio)
            let withSpeakers = mapSpeakers(allSegments, diar: diar)

            await storage.updateSegments(noteId: noteId, segments: withSpeakers)

            await update(noteId, stage: .summarizing, progress: 0.80, eta: 10, msg: "Zusammenfassung wird erstellt…")
            let fullText = withSpeakers.map { $0.text }.joined(separator: " ")
            var base = await llm.summarize(transcript: fullText)

            base.citations = withSpeakers.prefix(12).map(\.id)

            await update(noteId, stage: .roleSummaries, progress: 0.88, eta: 5, msg: "Rollenbasierte Auswertungen…")
            let roles = ["Sales", "Team", "Leadership"]
            var roleSummaries: [String: Summary] = [:]
            for r in roles {
                roleSummaries[r] = try await highlight.roleSummary(role: r, transcript: fullText, segments: withSpeakers)
            }

            await update(noteId, stage: .mindmap, progress: 0.92, eta: 3, msg: "Mindmap generieren…")
            let mind = try await highlight.makeMindmap(transcript: fullText)

            await storage.updateSummaries(noteId: noteId, summary: base, roleSummaries: roleSummaries, mindmap: mind)

            await update(noteId, stage: .indexing, progress: 0.96, eta: 1, msg: "Index aktualisieren…")
            let notes = await storage.loadAll()
            search.buildIndex(notes: notes)

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
        let req = UNNotificationRequest(identifier: "done-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func estimateETA(_ chunksRemaining: Int, perChunk: Int) -> Int { chunksRemaining * perChunk }

    private func mapSpeakers(
        _ segments: [TranscriptSegment],
        diar: [(start: TimeInterval, end: TimeInterval, speakerId: String)]
    ) -> [TranscriptSegment] {
        if diar.isEmpty {
            return segments
        }
        return segments.map { seg in
            var s = seg
            if let d = diar.first(where: { $0.start <= seg.start && seg.end <= $0.end }) {
                s.speakerId = d.speakerId
            }
            return s
        }
    }
}

extension Notification.Name {
    static let pipelineUpdated = Notification.Name("pipelineUpdated")
    static let notesChanged = Notification.Name("notesChanged")
}
