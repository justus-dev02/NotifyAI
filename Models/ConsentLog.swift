//
//  ConsentLog.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

struct ConsentLog: Codable, Hashable {
    var date: Date
    var participants: [String]
    var location: String?
    var confirmed: Bool
}
