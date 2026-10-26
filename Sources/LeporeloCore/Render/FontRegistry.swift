import CoreText
import Foundation

/// Registers the bundled OFL fonts (variable TTFs) for the current process.
///
/// Both fonts are variable fonts; they are used at their default axis values (Fraunces
/// opsz/wght/SOFT/WONK defaults, Schibsted Grotesk wght 400). No weight axis is selected
/// by the renderer.
///
/// Where the files live: the package declares `.copy("Resources")`, so SwiftPM puts them in the
/// target's resource bundle (`Leporelo_LeporeloCore.bundle`) under `Resources/Fonts/`.
/// `Bundle.module` finds that bundle next to the executable (SwiftPM) or in the app's
/// `Contents/Resources` (an Xcode app target that links the package product embeds the resource
/// bundle automatically), so no extra build phase is needed; Task 17 only has to link the
/// `LeporeloCore` product and keep the resource bundle in the app.
public enum FontRegistry {
    public static let titleFont = "Fraunces"
    public static let textFont = "Schibsted Grotesk"

    private static let fileNames = ["Fraunces", "SchibstedGrotesk"]

    private static func fontURL(_ name: String) -> URL? {
        let bundle = Bundle.module
        for sub in ["Resources/Fonts", "Fonts", nil] as [String?] {
            if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: sub) { return url }
        }
        return nil
    }

    /// Static lets are initialised lazily and exactly once, thread-safely. The value is the list
    /// of registration problems (empty on success; "already registered" counts as success).
    private static let registration: [String] = {
        var problems: [String] = []
        for name in fileNames {
            guard let url = fontURL(name) else {
                problems.append("\(name).ttf not found in bundle resources")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let cfError = error?.takeRetainedValue()
                let code = cfError.map { CFErrorGetCode($0) } ?? 0
                if code != Int(CTFontManagerError.alreadyRegistered.rawValue) {
                    problems.append("\(name).ttf: \(cfError.map { String(describing: $0) } ?? "unknown error")")
                }
            }
        }
        for problem in problems { NSLog("FontRegistry: %@", problem) }
        return problems
    }()

    /// Idempotent and thread-safe.
    public static func registerBundledFonts() {
        _ = registration
    }

    /// Problems found while registering (empty when everything registered).
    public static var registrationProblems: [String] {
        registration
    }

    /// True only if both families resolve to the right family names after registration.
    public static var areBundledFontsAvailable: Bool {
        registerBundledFonts()
        func family(_ name: String) -> String {
            CTFontCopyFamilyName(CTFontCreateWithName(name as CFString, 12, nil)) as String
        }
        return family(titleFont) == titleFont && family(textFont) == textFont
    }
}
