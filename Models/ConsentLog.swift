//
//  ConsentLog.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct ConsentLog: Codable {
    var date: Date
    var participants: [String]     // optionale Namen/Teams
    var location: String?          // Ort/Meetingraum
    var confirmed: Bool            // explizite Zustimmung
}
