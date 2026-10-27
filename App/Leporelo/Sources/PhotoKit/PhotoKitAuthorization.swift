import LeporeloCore
import Photos

/// Access to the Apple Photos library.
///
/// Leporelo needs FULL read access (`.readWrite` access level: PhotoKit has no read-only level
/// that covers the whole library, and `.addOnly` cannot read). The UI calls `request()` before it
/// creates a `PhotoKitSource`; the source itself never prompts, it only checks the status.
enum PhotoKitAuthorization {
    static let accessLevel: PHAccessLevel = .readWrite

    /// The current status, without prompting.
    static func currentStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: accessLevel)
    }

    /// Shows the system prompt when the status is `.notDetermined`; otherwise returns the
    /// current status immediately. Returns the final status.
    static func request() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: accessLevel)
    }

    /// Only full access lets the source read the library. `.limited` is refused on purpose: the
    /// fetch result would be a partial set and `SourceSync` would flag every photo outside the
    /// user's selection as deleted in the source.
    static func allowsReading(_ status: PHAuthorizationStatus) -> Bool {
        switch status {
        case .authorized: true
        case .notDetermined, .restricted, .denied, .limited: false
        @unknown default: false
        }
    }

    /// Throws `PhotoSourceError.notAuthorized` unless full access was granted. Never prompts.
    static func ensureAuthorized(status: PHAuthorizationStatus = currentStatus()) throws {
        guard allowsReading(status) else { throw PhotoSourceError.notAuthorized }
    }
}
