//
//  LicenseTests.swift
//  NotifyAITests
//
//  The licenses page: every entry that ships a license text finds it in the bundle.
//

import Foundation
@testable import NotifyAI
import Testing

@Suite("Licenses")
@MainActor
struct LicenseTests {
    @Test("Every bundled license text exists and is not empty")
    func licenseTexts() throws {
        for entry in [Acknowledgement.app] + Acknowledgement.all where entry.licenseFile != nil {
            let text = try #require(entry.licenseText, "\(entry.name)")
            #expect(text.count > 500, "\(entry.name)")
        }
    }

    @Test("The app's own license is MIT with its copyright")
    func appLicense() throws {
        let text = try #require(Acknowledgement.app.licenseText)
        #expect(text.hasPrefix("MIT License"))
        #expect(text.contains(Acknowledgement.app.copyright))
    }

    @Test("Models under CC BY 4.0 link their license")
    func attribution() {
        for entry in Acknowledgement.all where entry.license == "CC BY 4.0" {
            #expect(entry.licenseLink != nil, "\(entry.name)")
            #expect(entry.note != nil, "\(entry.name)")
        }
    }
}
