import Foundation
import Testing
import LeporeloCore

/// The tests run inside the Leporelo.app test host, so these prove the SwiftPM resource bundle of
/// LeporeloCore is embedded in the app and found at runtime.
struct ResourceBundleTests {
    @Test func appEmbedsLeporeloCoreResourceBundle() throws {
        let bundleURL = try #require(Bundle.main.resourceURL)
            .appendingPathComponent("Leporelo_LeporeloCore.bundle")
        // Xcode builds a macOS bundle (Contents/Resources); `.copy("Resources")` keeps the folder.
        let bundle = try #require(Bundle(url: bundleURL))
        let resources = try #require(bundle.resourceURL).appendingPathComponent("Resources")
        let fonts = try FileManager.default.contentsOfDirectory(atPath: resources.appendingPathComponent("Fonts").path)
        let profiles = try FileManager.default.contentsOfDirectory(atPath: resources.appendingPathComponent("Profiles").path)
        #expect(fonts.contains("Fraunces.ttf"))
        #expect(fonts.contains("SchibstedGrotesk.ttf"))
        #expect(profiles.contains { $0.hasSuffix(".json") })
    }

    @Test func bundledFontsAreAvailable() {
        #expect(FontRegistry.areBundledFontsAvailable)
        #expect(FontRegistry.registrationProblems.isEmpty)
    }

    @Test func profileCatalogLoads() throws {
        let profiles = try ProfileCatalog.all()
        #expect(!profiles.isEmpty)
        #expect(profiles.contains { $0.id == "canva-photobook" })
    }
}
