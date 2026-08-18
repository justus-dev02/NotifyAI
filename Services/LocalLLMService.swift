//
//  LocalLLMService.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//  Updated for Real On-Device NLP & LLM Operations.
//

import Foundation

class LocalLLMService: ObservableObject {
    static let shared = LocalLLMService()
    
    @Published var isProcessing = false
    @Published var currentModel: LLMModel = .onDeviceNLP
    @Published var processingProgress: Double = 0
    
    enum LLMModel: String, CaseIterable, Identifiable {
        case onDeviceNLP = "on-device-nlp"
        case phi3Mini = "phi-3-mini"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .onDeviceNLP: return "Apple Neural NLP (Integrierter Standard)"
            case .phi3Mini: return "Phi-3 Mini (1.8GB)"
            }
        }
    }
    
    private init() {}
    
    // MARK: - Text Processing
    
    func summarizeText(_ text: String, template: SummaryTemplate) async throws -> String {
        isProcessing = true
        processingProgress = 0.5
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        let summary = await ServiceLocator.shared.llm.summarize(transcript: text)
        return summary.markdown
    }
    
    func generateMindmap(from text: String) async throws -> Mindmap {
        isProcessing = true
        processingProgress = 0.5
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        return try await ServiceLocator.shared.highlight.makeMindmap(transcript: text)
    }
    
    func extractActionItems(from text: String) async throws -> [ActionItem] {
        isProcessing = true
        processingProgress = 0.5
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        let summary = await ServiceLocator.shared.llm.summarize(transcript: text)
        return summary.actionItems
    }
    
    func generateRoleSummary(from text: String, role: String) async throws -> String {
        isProcessing = true
        processingProgress = 0.5
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        let summary = try await ServiceLocator.shared.highlight.roleSummary(role: role, transcript: text, segments: [])
        return summary.markdown
    }
}

// MARK: - Summary Templates

enum SummaryTemplate: String, CaseIterable, Identifiable {
    case executive = "executive"
    case detailed = "detailed"
    case bulletPoints = "bulletPoints"
    case meeting = "meeting"
    case lecture = "lecture"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .executive: return "Executive Summary"
        case .detailed: return "Detaillierte Zusammenfassung"
        case .bulletPoints: return "Stichpunkte"
        case .meeting: return "Meeting Summary"
        case .lecture: return "Vorlesungs Summary"
        }
    }
    
    var description: String {
        switch self {
        case .executive: return "Kurze, prägnante Zusammenfassung für Führungskräfte"
        case .detailed: return "Ausführliche Zusammenfassung mit allen Details"
        case .bulletPoints: return "Strukturierte Aufzählung der wichtigsten Punkte"
        case .meeting: return "Speziell für Meetings optimiert"
        case .lecture: return "Für Vorlesungen und Bildungsinhalte"
        }
    }
}

// MARK: - Error Types

enum LLError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case processingFailed
    
    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "LLM model not found"
        case .modelNotLoaded:
            return "LLM model not loaded"
        case .processingFailed:
            return "Text processing failed"
        }
    }
}
