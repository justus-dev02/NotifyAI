//
//  App.swift
//  NotifyAI
//
//  Created by Justus on 23.09.25.
//

import Foundation

/// Minimal dependency container used for previews and SwiftUI environment set-up.
/// The previous placeholder code referenced symbols that do not exist in this project,
/// which caused compilation to fail. The simplified version below just exposes the
/// shared `ServiceLocator` instance so that other parts of the app can resolve their
/// dependencies without pulling in additional frameworks.
struct AppDependencies {
    static let shared = AppDependencies()

    /// The global service locator that is injected into the SwiftUI hierarchy.
    let serviceLocator = ServiceLocator.shared

    private init() {}
}
