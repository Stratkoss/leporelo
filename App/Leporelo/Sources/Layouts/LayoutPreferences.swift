import Foundation
import LeporeloCore

/// The layouts the user likes (spec 6), for the whole app in `UserDefaults`. The core never sees
/// the defaults: the app hands it `weights()`.
struct LayoutPreferences {
    static let likedKey = "layouts.liked"
    static let askedKey = "layouts.asked"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Layout ids marked as favourites.
    var liked: Set<String> {
        Set(defaults.stringArray(forKey: Self.likedKey) ?? [])
    }

    /// True once the choice was finished or skipped; the app does not ask again by itself.
    var asked: Bool {
        defaults.bool(forKey: Self.askedKey)
    }

    var needsOnboarding: Bool { !asked }

    /// Nothing liked: weight 1 for all; else 3 for the liked ones, 1 for the rest.
    func weights() -> LayoutWeights {
        LayoutWeights(liked: liked)
    }

    /// "Hotovo", and "Přeskočit" of the first-time choice (an empty set): stores the choice and
    /// that nobody needs to ask.
    mutating func finish(liked: Set<String>) {
        defaults.set(liked.sorted(), forKey: Self.likedKey)
        defaults.set(true, forKey: Self.askedKey)
    }

    /// "Přeskočit" in the menu window: the favourites stay as they are; only records that the
    /// choice was offered, so the first "Udělat z toho knihu" does not ask again.
    mutating func skip() {
        if !asked { defaults.set(true, forKey: Self.askedKey) }
    }
}
