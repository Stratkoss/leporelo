import CoreText
import Foundation

/// Registers the bundled OFL fonts (variable TTFs) for the current process.
///
/// Each book family has a roman and an italic file (`Fraunces`, `Fraunces-Italic`,
/// `SchibstedGrotesk`, `SchibstedGrotesk-Italic`); the italic files belong to the same families,
/// so an italic is picked by trait like any Mac font. All four are variable fonts used at their
/// default axis values (Fraunces opsz/wght/SOFT/WONK defaults, Schibsted Grotesk wght 400) except
/// that bold sets the `wght` axis to 700 (`SpreadRenderer.ctFont(for:)`).
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

    private static let fileNames = ["Fraunces", "Fraunces-Italic", "SchibstedGrotesk", "SchibstedGrotesk-Italic"]

    static func fontURL(_ name: String) -> URL? {
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

    // MARK: Families

    /// The OpenType tag of the weight axis.
    static let weightAxisTag = 0x7767_6874 // 'wght'

    /// The largest value of the font's `wght` axis, nil when it has none.
    static func weightAxisMax(_ font: CTFont) -> Double? {
        let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
        let axis = axes.first { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == weightAxisTag }
        return (axis?[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue
    }

    private static func familyDescriptors(_ family: String) -> [CTFontDescriptor] {
        registerBundledFonts()
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String]
        return CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory as CFSet) as? [CTFontDescriptor] ?? []
    }

    /// True when a font of `family` (a bundled or installed family name) can be drawn on this Mac.
    public static func isFamilyAvailable(_ family: String) -> Bool {
        registerBundledFonts()
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String]
        return CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatory as CFSet) != nil
    }

    /// Whether `family` can be drawn bold (a bold face or a `wght` axis reaching 700) and italic
    /// (an italic face). Both false for a missing family.
    public static func availableTraits(family: String) -> (bold: Bool, italic: Bool) {
        var bold = false, italic = false
        for descriptor in familyDescriptors(family) {
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolic = CTFontSymbolicTraits(rawValue: (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0)
            italic = italic || symbolic.contains(.traitItalic)
            if !bold {
                let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
                bold = symbolic.contains(.traitBold) || (weightAxisMax(font) ?? 0) >= 700
            }
            if bold && italic { break }
        }
        return (bold, italic)
    }

    /// The families a text can use: the two book fonts first, then the families installed on this
    /// Mac A–Z (hidden system families left out), each once.
    public static func allFamilies() -> [String] {
        registerBundledFonts()
        let book = [titleFont, textFont]
        let installed = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let rest = Set(installed.filter { !$0.hasPrefix(".") && !book.contains($0) })
        return book + rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
