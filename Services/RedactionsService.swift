//
//  RedactionsService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

final class RedactionService {
    func redactPII(_ text: String) -> String {
        var out = text
        // E-Mail
        let emailPattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        out = out.replacingOccurrences(of: emailPattern, with: "[EMAIL]", options: .regularExpression)
        // Telefonnummer (vereinfachte Variante)
        let phonePattern = #"(?:\+?\d[\d\-\s]{6,}\d)"#
        out = out.replacingOccurrences(of: phonePattern, with: "[PHONE]", options: .regularExpression)
        // Optional: einfache Personennamenliste -> [NAME] (nur Beispiel)
        return out
    }
}
