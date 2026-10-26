import Foundation

public enum ProfileCatalogError: Error, Equatable {
    case resourcesMissing
    case profileNotFound(String)
    case formatNotFound(profileID: String, formatID: String)
}

public enum ProfileCatalog {
    public static func all() throws -> [SupplierProfile] {
        // `.copy("Resources")` keeps the folder, so profiles live in <bundle>/Resources/Profiles.
        let dir = Bundle.module.bundleURL.appendingPathComponent("Resources/Profiles", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw ProfileCatalogError.resourcesMissing
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        return try files.map { try decoder.decode(SupplierProfile.self, from: Data(contentsOf: $0)) }
    }

    public static func profile(id: String) throws -> SupplierProfile {
        guard let p = try all().first(where: { $0.id == id }) else {
            throw ProfileCatalogError.profileNotFound(id)
        }
        return p
    }

    public static func format(profileID: String, formatID: String) throws -> (SupplierProfile, BookFormat) {
        let p = try profile(id: profileID)
        guard let f = p.formats.first(where: { $0.id == formatID }) else {
            throw ProfileCatalogError.formatNotFound(profileID: profileID, formatID: formatID)
        }
        return (p, f)
    }
}
