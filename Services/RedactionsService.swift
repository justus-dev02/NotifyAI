//
//  RedactionsService.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//  Updated for Comprehensive German & International PII Redaction.
//

import Foundation

final class RedactionService {
    func redactPII(_ text: String) -> String {
        var out = text
        // E-Mail
        let emailPattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        out = out.replacingOccurrences(of: emailPattern, with: "[E-Mail]", options: .regularExpression)

        // Telefonnummer (internationale und lokale Formate)
        let phonePattern = #"(?:\+?\d{1,3}[-.\s]?)?\(?\d{2,4}\)?[-.\s]?\d{3,4}[-.\s]?\d{3,9}"#
        out = out.replacingOccurrences(of: phonePattern, with: "[Telefonnummer]", options: .regularExpression)

        // IBAN (deutsches / europäisches Format)
        let ibanPattern = #"[A-Z]{2}\d{2}[A-Z0-9]{12,30}"#
        out = out.replacingOccurrences(of: ibanPattern, with: "[IBAN]", options: .regularExpression)

        return out
    }
}
