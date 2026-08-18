//
//  LearningModels.swift
//  NotifyAI
//
//  Created by AI Assistant on 23.10.25.
//

import Foundation

// MARK: - Flashcard

struct Flashcard: Identifiable, Codable, Hashable {
    let id: UUID
    var front: String
    var back: String
    var category: String
    var difficulty: Difficulty
    var createdAt: Date
    var lastReviewed: Date?
    var reviewCount: Int
    var correctCount: Int
    var nextReviewDate: Date?
    
    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        category: String = "General",
        difficulty: Difficulty = .medium
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.category = category
        self.difficulty = difficulty
        self.createdAt = Date()
        self.reviewCount = 0
        self.correctCount = 0
    }
    
    var accuracy: Double {
        guard reviewCount > 0 else { return 0 }
        return Double(correctCount) / Double(reviewCount)
    }
    
    var isDueForReview: Bool {
        guard let nextReviewDate = nextReviewDate else { return true }
        return Date() >= nextReviewDate
    }
}

enum Difficulty: String, CaseIterable, Codable {
    case easy = "easy"
    case medium = "medium"
    case hard = "hard"
    
    var displayName: String {
        switch self {
        case .easy: return "Einfach"
        case .medium: return "Mittel"
        case .hard: return "Schwer"
        }
    }
    
    var color: String {
        switch self {
        case .easy: return "#32CD32"
        case .medium: return "#FFA500"
        case .hard: return "#FF6347"
        }
    }
}

// MARK: - Quiz

struct Quiz: Identifiable, Codable {
    let id: UUID
    var title: String
    var description: String
    var questions: [QuizQuestion]
    var category: String
    var difficulty: Difficulty
    var timeLimit: TimeInterval?
    var createdAt: Date
    var attempts: [QuizAttempt]
    
    init(
        id: UUID = UUID(),
        title: String,
        description: String,
        questions: [QuizQuestion] = [],
        category: String = "General",
        difficulty: Difficulty = .medium,
        timeLimit: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.questions = questions
        self.category = category
        self.difficulty = difficulty
        self.timeLimit = timeLimit
        self.createdAt = Date()
        self.attempts = []
    }
    
    var averageScore: Double {
        guard !attempts.isEmpty else { return 0 }
        let totalScore = attempts.reduce(0) { $0 + $1.score }
        return totalScore / Double(attempts.count)
    }
    
    var bestScore: Double {
        return attempts.map { $0.score }.max() ?? 0
    }
}

struct QuizQuestion: Identifiable, Codable {
    let id: UUID
    var question: String
    var options: [String]
    var correctAnswer: Int
    var explanation: String?
    var category: String
    var difficulty: Difficulty
    
    init(
        id: UUID = UUID(),
        question: String,
        options: [String],
        correctAnswer: Int,
        explanation: String? = nil,
        category: String = "General",
        difficulty: Difficulty = .medium
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.correctAnswer = correctAnswer
        self.explanation = explanation
        self.category = category
        self.difficulty = difficulty
    }
}

struct QuizAttempt: Identifiable, Codable {
    let id: UUID
    var answers: [Int]
    var score: Double
    var timeSpent: TimeInterval
    var completedAt: Date
    var isCompleted: Bool
    
    init(
        id: UUID = UUID(),
        answers: [Int] = [],
        score: Double = 0,
        timeSpent: TimeInterval = 0,
        completedAt: Date = Date(),
        isCompleted: Bool = false
    ) {
        self.id = id
        self.answers = answers
        self.score = score
        self.timeSpent = timeSpent
        self.completedAt = completedAt
        self.isCompleted = isCompleted
    }
}

// MARK: - Learning Session

struct LearningSession: Identifiable, Codable {
    let id: UUID
    var flashcards: [Flashcard]
    var currentIndex: Int
    var startTime: Date
    var endTime: Date?
    var isCompleted: Bool
    var correctAnswers: Int
    var totalQuestions: Int
    
    init(
        id: UUID = UUID(),
        flashcards: [Flashcard] = [],
        currentIndex: Int = 0
    ) {
        self.id = id
        self.flashcards = flashcards
        self.currentIndex = currentIndex
        self.startTime = Date()
        self.isCompleted = false
        self.correctAnswers = 0
        self.totalQuestions = flashcards.count
    }
    
    var progress: Double {
        guard totalQuestions > 0 else { return 0 }
        return Double(currentIndex) / Double(totalQuestions)
    }
    
    var score: Double {
        guard totalQuestions > 0 else { return 0 }
        return Double(correctAnswers) / Double(totalQuestions)
    }
    
    var currentFlashcard: Flashcard? {
        guard currentIndex < flashcards.count else { return nil }
        return flashcards[currentIndex]
    }
    
    mutating func answerCorrect() {
        correctAnswers += 1
        nextQuestion()
    }
    
    mutating func answerIncorrect() {
        nextQuestion()
    }
    
    private mutating func nextQuestion() {
        currentIndex += 1
        if currentIndex >= flashcards.count {
            isCompleted = true
            endTime = Date()
        }
    }
}

// MARK: - Learning Analytics

struct LearningAnalytics: Codable {
    var totalStudyTime: TimeInterval
    var totalFlashcards: Int
    var totalQuizzes: Int
    var averageAccuracy: Double
    var streakDays: Int
    var lastStudyDate: Date?
    var categories: [String: CategoryAnalytics]
    
    init() {
        self.totalStudyTime = 0
        self.totalFlashcards = 0
        self.totalQuizzes = 0
        self.averageAccuracy = 0
        self.streakDays = 0
        self.categories = [:]
    }
}

struct CategoryAnalytics: Codable {
    var studyTime: TimeInterval
    var flashcardCount: Int
    var quizCount: Int
    var averageAccuracy: Double
    var lastStudied: Date?
    
    init() {
        self.studyTime = 0
        self.flashcardCount = 0
        self.quizCount = 0
        self.averageAccuracy = 0
    }
}

// MARK: - Learning Generator

class LearningGenerator: ObservableObject {
    func generateFlashcards(from text: String, count: Int = 10) async throws -> [Flashcard] {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return [] }
        
        let sentences = cleanText.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 10 }
        
        var cards: [Flashcard] = []
        for sentence in sentences.prefix(count) {
            let words = sentence.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 3 }
            let topic = words.first ?? "Kernpunkt"
            cards.append(Flashcard(
                front: "Welcher Aspekt wird bezüglich '\(topic)' festgehalten?",
                back: sentence,
                category: "Lerninhalt",
                difficulty: .medium
            ))
        }
        return cards
    }
    
    func generateQuiz(from text: String, questionCount: Int = 5) async throws -> Quiz {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = cleanText.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 12 }
        
        var questions: [QuizQuestion] = []
        for (index, sentence) in sentences.prefix(questionCount).enumerated() {
            let options = [
                sentence,
                "Wurde im Gespräch nicht explizit thematisiert.",
                "Es wurde das Gegenteil vereinbart.",
                "Steht noch unter Vorbehalt."
            ].shuffled()
            
            let correctIdx = options.firstIndex(of: sentence) ?? 0
            
            questions.append(QuizQuestion(
                question: "Welche der folgenden Aussagen entspricht dem Inhalt aus Abschnitt \(index + 1)?",
                options: options,
                correctAnswer: correctIdx,
                explanation: "Der korrekte Inhalt lautet: \"\(sentence)\"",
                category: "Verständnis",
                difficulty: .medium
            ))
        }
        
        return Quiz(
            title: "Verständnis-Quiz zum Gespräch",
            description: "Automatisch generiertes Quiz basierend auf den transkribierten Inhalten.",
            questions: questions,
            category: "Gesprächsinhalt",
            difficulty: .medium
        )
    }
    
    func generateSummaryForLearning(from text: String) async throws -> String {
        let summary = await ServiceLocator.shared.llm.summarize(transcript: text)
        return summary.markdown
    }
}
