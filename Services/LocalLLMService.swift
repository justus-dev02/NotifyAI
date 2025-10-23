//
//  LocalLLMService.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import Foundation
import CoreML

class LocalLLMService: ObservableObject {
    static let shared = LocalLLMService()
    
    @Published var isProcessing = false
    @Published var currentModel: LLMModel = .phi3Mini
    @Published var processingProgress: Double = 0
    
    private var model: MLModel?
    private var tokenizer: Tokenizer?
    
    enum LLMModel: String, CaseIterable, Identifiable {
        case phi3Mini = "phi-3-mini"
        case phi3MiniInt8 = "phi-3-mini-int8"
        case llama38B = "llama-3-8b"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .phi3Mini: return "Phi-3 Mini (1.8GB)"
            case .phi3MiniInt8: return "Phi-3 Mini Int8 (3.2GB)"
            case .llama38B: return "LLaMA 3 8B (4.5GB)"
            }
        }
        
        var modelPath: String {
            switch self {
            case .phi3Mini: return "phi3_mini"
            case .phi3MiniInt8: return "phi3_mini_int8"
            case .llama38B: return "llama3_8b"
            }
        }
    }
    
    private init() {
        loadModel()
    }
    
    // MARK: - Model Management
    
    private func loadModel() {
        Task {
            do {
                let modelURL = try getModelURL(for: currentModel)
                model = try MLModel(contentsOf: modelURL)
                tokenizer = Tokenizer(model: currentModel)
            } catch {
                print("Error loading model: \(error)")
            }
        }
    }
    
    private func getModelURL(for model: LLMModel) throws -> URL {
        guard let modelPath = Bundle.main.path(forResource: model.modelPath, ofType: "mlmodelc") else {
            throw LLError.modelNotFound
        }
        return URL(fileURLWithPath: modelPath)
    }
    
    func switchModel(to newModel: LLMModel) {
        currentModel = newModel
        loadModel()
    }
    
    // MARK: - Text Processing
    
    func summarizeText(_ text: String, template: SummaryTemplate) async throws -> String {
        guard let model = model, let tokenizer = tokenizer else {
            throw LLError.modelNotLoaded
        }
        
        isProcessing = true
        processingProgress = 0
        
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        let prompt = template.createPrompt(for: text)
        let tokens = try tokenizer.tokenize(prompt)
        
        // Simulate processing with progress updates
        for i in 0...10 {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            processingProgress = Double(i) / 10.0
        }
        
        // In a real implementation, this would use the ML model
        // For now, we'll return a mock summary
        return generateMockSummary(for: text, template: template)
    }
    
    func generateMindmap(from text: String) async throws -> Mindmap {
        guard let model = model, let tokenizer = tokenizer else {
            throw LLError.modelNotLoaded
        }
        
        isProcessing = true
        processingProgress = 0
        
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        // Simulate processing
        for i in 0...10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            processingProgress = Double(i) / 10.0
        }
        
        return generateMockMindmap(from: text)
    }
    
    func extractActionItems(from text: String) async throws -> [ActionItem] {
        guard let model = model, let tokenizer = tokenizer else {
            throw LLError.modelNotLoaded
        }
        
        isProcessing = true
        processingProgress = 0
        
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        // Simulate processing
        for i in 0...10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            processingProgress = Double(i) / 10.0
        }
        
        return generateMockActionItems(from: text)
    }
    
    func generateRoleSummary(from text: String, role: String) async throws -> String {
        guard let model = model, let tokenizer = tokenizer else {
            throw LLError.modelNotLoaded
        }
        
        isProcessing = true
        processingProgress = 0
        
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        // Simulate processing
        for i in 0...10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            processingProgress = Double(i) / 10.0
        }
        
        return generateMockRoleSummary(from: text, role: role)
    }
    
    // MARK: - Mock Implementations (Replace with actual ML model calls)
    
    private func generateMockSummary(for text: String, template: SummaryTemplate) -> String {
        let sentences = text.components(separatedBy: ". ").filter { !$0.isEmpty }
        let keySentences = Array(sentences.prefix(3))
        
        switch template {
        case .executive:
            return "Executive Summary:\n\n" + keySentences.joined(separator: ". ") + "."
        case .detailed:
            return "Detailed Summary:\n\n" + text.prefix(500) + "..."
        case .bulletPoints:
            return "Key Points:\n\n• " + keySentences.joined(separator: "\n• ")
        case .meeting:
            return "Meeting Summary:\n\n" + keySentences.joined(separator: ". ") + "."
        case .lecture:
            return "Lecture Summary:\n\n" + keySentences.joined(separator: ". ") + "."
        }
    }
    
    private func generateMockMindmap(from text: String) -> Mindmap {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .prefix(5)
        
        let root = "Hauptthema"
        let children = words.map { word in
            MindmapNode(label: word, children: nil)
        }
        
        return Mindmap(root: root, children: Array(children))
    }
    
    private func generateMockActionItems(from text: String) -> [ActionItem] {
        let sentences = text.components(separatedBy: ". ")
        let actionSentences = sentences.filter { 
            $0.lowercased().contains("todo") || 
            $0.lowercased().contains("aufgabe") ||
            $0.lowercased().contains("action")
        }
        
        return actionSentences.prefix(3).enumerated().map { index, sentence in
            ActionItem(
                task: sentence,
                status: .open
            )
        }
    }
    
    private func generateMockRoleSummary(from text: String, role: String) -> String {
        return "\(role) Summary:\n\n" + text.prefix(200) + "..."
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
    
    func createPrompt(for text: String) -> String {
        switch self {
        case .executive:
            return "Erstelle eine Executive Summary für folgenden Text:\n\n\(text)"
        case .detailed:
            return "Erstelle eine detaillierte Zusammenfassung für folgenden Text:\n\n\(text)"
        case .bulletPoints:
            return "Erstelle eine Stichpunkt-Liste für folgenden Text:\n\n\(text)"
        case .meeting:
            return "Erstelle eine Meeting-Zusammenfassung für folgenden Text:\n\n\(text)"
        case .lecture:
            return "Erstelle eine Vorlesungs-Zusammenfassung für folgenden Text:\n\n\(text)"
        }
    }
}

// MARK: - Tokenizer

class Tokenizer {
    private let model: LocalLLMService.LLMModel
    
    init(model: LocalLLMService.LLMModel) {
        self.model = model
    }
    
    func tokenize(_ text: String) throws -> [Int] {
        // In a real implementation, this would use the appropriate tokenizer
        // For now, we'll return a simple word-based tokenization
        return text.components(separatedBy: .whitespacesAndNewlines)
            .enumerated()
            .map { $0.offset }
    }
    
    func detokenize(_ tokens: [Int]) -> String {
        // In a real implementation, this would convert tokens back to text
        return "Detokenized text"
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
