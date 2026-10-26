import CoreText
import Foundation

/// Registers the bundled OFL fonts (variable TTFs) for the current process.
///
/// Both fonts are variable fonts; they are used at their default axis values (Fraunces
/// opsz/wght/SOFT/WONK defaults, Schibsted Grotesk wght 400). No weight axis is selected
/// by the renderer.
public enum FontRegistry {
    public static let titleFont = "Fraunces"
    public static let textFont = "Schibsted Grotesk"

    private static let files = ["Fraunces.ttf", "SchibstedGrotesk.ttf"]

    /// Static lets are initialised lazily and exactly once, thread-safely.
    private static let registration: Void = {
        let dir = Bundle.module.bundleURL.appendingPathComponent("Resources/Fonts", isDirectory: true)
        for file in files {
            // Errors (e.g. already registered by the host app) are ignored on purpose.
            _ = CTFontManagerRegisterFontsForURL(dir.appendingPathComponent(file) as CFURL, .process, nil)
        }
    }()

    /// Idempotent and thread-safe.
    public static func registerBundledFonts() {
        _ = registration
    }
}
