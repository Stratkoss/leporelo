import Foundation
import LeporeloCore
import Testing
@testable import Leporelo

@Suite("LayoutPreferences")
struct LayoutPreferencesTests {
    /// Every test has its own defaults, never `.standard`.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    @Test func freshNeedsOnboardingEqualWeights() {
        let preferences = LayoutPreferences(defaults: freshDefaults())
        #expect(preferences.needsOnboarding)
        #expect(!preferences.asked)
        #expect(preferences.liked.isEmpty)
        #expect(preferences.weights().weight("grid-4") == 1)
    }

    @Test func finishWithLikesWeighsThree() {
        var preferences = LayoutPreferences(defaults: freshDefaults())
        preferences.finish(liked: ["mosaic-6"])
        #expect(preferences.weights().weight("mosaic-6") == 3)
        #expect(preferences.weights().weight("grid-4") == 1)
        #expect(!preferences.needsOnboarding)
    }

    @Test func skipStoresAskedNoLikes() {
        var preferences = LayoutPreferences(defaults: freshDefaults())
        preferences.finish(liked: [])
        #expect(preferences.asked)
        #expect(preferences.liked.isEmpty)
        for id in PageLayoutCatalog.favouriteCandidates {
            #expect(preferences.weights().weight(id) == 1)
        }
    }

    /// The choice is for the whole app: another value over the same defaults sees it, stored
    /// under the documented keys.
    @Test func storedUnderDocumentedKeysAndSharedAcrossInstances() {
        let defaults = freshDefaults()
        var preferences = LayoutPreferences(defaults: defaults)
        preferences.finish(liked: ["grid-4", "mosaic-5"])
        #expect(Set(defaults.stringArray(forKey: "layouts.liked") ?? []) == ["grid-4", "mosaic-5"])
        #expect(defaults.bool(forKey: "layouts.asked"))
        let again = LayoutPreferences(defaults: defaults)
        #expect(again.liked == ["grid-4", "mosaic-5"])
        #expect(!again.needsOnboarding)
    }

    /// "Přeskočit" in the menu window keeps the stored favourites; it only records the question.
    @Test func skipKeepsStoredLikesAndMarksAsked() {
        let defaults = freshDefaults()
        var preferences = LayoutPreferences(defaults: defaults)
        preferences.skip()
        #expect(preferences.asked)
        #expect(preferences.liked.isEmpty)
        preferences.finish(liked: ["grid-4", "mosaic-5"])
        preferences.skip()
        #expect(preferences.liked == ["grid-4", "mosaic-5"])
        #expect(preferences.weights().weight("grid-4") == 3)
        #expect(LayoutPreferences(defaults: defaults).asked)
    }

    /// Opened again from the menu, "Hotovo" with fewer marks replaces the old choice.
    @Test func finishReplacesEarlierLikes() {
        var preferences = LayoutPreferences(defaults: freshDefaults())
        preferences.finish(liked: ["grid-4"])
        preferences.finish(liked: [])
        #expect(preferences.liked.isEmpty)
        #expect(preferences.weights().weight("grid-4") == 1)
    }
}
