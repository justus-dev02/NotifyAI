//
//  NotifyAIApp.swift
//  NotifyAI
//
//  Created by Justus on 08.09.25.
//

import SwiftUI

@main
struct NotifyAIApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
