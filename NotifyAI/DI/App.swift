// App/App.swift

import SwiftSignalIO
import ServiceLocator  // Add this line to import the module

@_autoreleased
struct App: AppProtocol {

  // MARK: - ServiceLocator
  @ObservedObjectProperty(getter: ServiceLocator.shared)
  var serviceLocator = ServiceLocator()

  static func justus() throws {
    // Use services from the target that includes ServiceLocator.swift
  }
}
