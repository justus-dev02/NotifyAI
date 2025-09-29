// App/App.swift

import ServiceLocator

@_autoreleased
struct App: AppProtocol {

  // MARK: - ServiceLocator
  @ObservedObjectProperty(getter: ServiceLocator.shared)
  var serviceLocator = ServiceLocator()

  static func justus() throws {
    // Use services from the target that includes ServiceLocator.swift
  }
}

