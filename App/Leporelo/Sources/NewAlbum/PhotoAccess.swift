import Foundation
import Photos

/// What the start window shows for each Photos authorization status. Only full access
/// enables the form: `PhotoKitSource` refuses everything else (a limited set would make
/// `SourceSync` flag the photos outside it as deleted).
enum PhotoAccess: Equatable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .limited: self = .limited
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }

    var allowsForm: Bool { self == .authorized }

    var explanation: String {
        switch self {
        case .notDetermined:
            "Leporelo potřebuje přístup k Fotkám, aby z nich mohlo vybrat fotky do alba. Fotky v knihovně nikdy nemění."
        case .denied:
            "Leporelo nemá přístup k Fotkám. Povolte ho v Nastavení systému v části Soukromí a zabezpečení › Fotky."
        case .restricted:
            "Přístup k Fotkám je na tomto Macu omezený systémem (například rodičovskou kontrolou nebo správou zařízení), takže ho Leporelo nemůže získat. Obraťte se na správce tohoto Macu."
        case .limited:
            "Leporelo má přístup jen k vybraným fotkám. Potřebuje úplný přístup: z částečného výběru by nepoznalo, které fotky z knihovny zmizely, a označilo by je jako smazané. Změňte to v Nastavení systému v části Soukromí a zabezpečení › Fotky."
        case .authorized:
            ""
        }
    }

    /// The button under the explanation (nil when the form is shown).
    var actionTitle: String? {
        switch self {
        case .notDetermined: "Povolit přístup k Fotkám"
        case .denied, .limited: "Otevřít Nastavení systému"
        // The user cannot lift a system restriction in Settings, so no button.
        case .restricted, .authorized: nil
        }
    }
}
