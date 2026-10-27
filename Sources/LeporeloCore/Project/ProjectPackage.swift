import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ProjectError: Error, Equatable, Sendable {
    /// The path is not a directory (or does not exist).
    case notAPackage
    /// The directory has no `album.json`.
    case missingAlbumFile
    /// `album.json` could not be read or decoded; carries the decoding error description.
    case corrupt(String)
    /// The album's `formatVersion` is older than we can migrate (no migrations yet) or newer than we know.
    case unsupportedVersion(Int)
    case alreadyExists
    /// A photo id or file extension that is not safe to use as a file name inside the package.
    case invalidName
    case writeFailed(String)
}

extension ProjectError: LocalizedError {
    /// Short Czech messages for the app (the UI language); the CLI prints `String(describing:)`.
    public var errorDescription: String? {
        switch self {
        case .notAPackage: "Tohle není album Leporela."
        case .missingAlbumFile: "V albu chybí soubor album.json."
        case .corrupt: "Album je poškozené a nejde přečíst."
        case .unsupportedVersion(let version) where version > Album.currentFormatVersion:
            "Album je z novější verze Leporela (formát \(version)). Aktualizujte aplikaci."
        case .unsupportedVersion(let version): "Album má nepodporovaný formát \(version)."
        case .alreadyExists: "Album s tímto názvem už existuje."
        case .invalidName: "Album obsahuje neplatný název souboru."
        case .writeFailed: "Album nejde uložit."
        }
    }
}

/// A Leporelo project on disk: the directory `<name>.leporelo/`
///
///     album.json                 the album (pretty printed, sorted keys, ISO 8601 dates)
///     originals/<photoID>.<ext>  full-resolution copies, so export never depends on iCloud
///     thumbs/<photoID>.jpg       upright JPEG previews, max 1024 px on the long side
///
/// Anti-goal: lost work. `save` writes to a temporary file in the package directory and swaps it
/// in, so a crash or failed write leaves the previous `album.json` intact.
///
/// Task 17's `AlbumDocument` calls `save` for autosave. The directory layout must stay valid when
/// macOS Versions copies the package; originals are large, so Task 17 decides how to avoid
/// duplicating them in version snapshots.
///
/// JSON goes through `AlbumCoding` (lossless fractional-second dates); Task 17's `AlbumDocument`
/// must use it too.
///
/// Writes of originals and thumbnails go through `writeCoordinator` (default: direct writes). The
/// app gives a package that a document has open an `NSFileCoordinator`-based one
/// (`coordinated(by:)`), so those writes cannot race the document's save; see
/// `PackageWriteCoordinator`.
///
/// The struct holds only the URL and the coordinator and performs stateless file operations, hence
/// it is `Sendable`.
public struct ProjectPackage: Sendable {
    public static let albumFileName = "album.json"
    static let originalsDirectory = "originals"
    static let thumbsDirectory = "thumbs"
    /// Long side of stored thumbnails, in pixels.
    public static let thumbnailMaxPixelSize = 1024

    public let url: URL
    /// What `storeOriginal` and `storeThumbnail` write through.
    public private(set) var writeCoordinator: any PackageWriteCoordinator = DirectPackageWrites()

    init(url: URL) { self.url = url }

    /// This package with its original and thumbnail writes going through `coordinator`.
    public func coordinated(by coordinator: any PackageWriteCoordinator) -> ProjectPackage {
        var package = self
        package.writeCoordinator = coordinator
        return package
    }

    // MARK: JSON

    private var albumURL: URL { url.appendingPathComponent(Self.albumFileName) }

    // MARK: Create / open / save

    public static func create(at url: URL, album: Album) throws -> ProjectPackage {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw ProjectError.alreadyExists }
        let package = ProjectPackage(url: url)
        do {
            try fm.createDirectory(at: url.appendingPathComponent(originalsDirectory),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent(thumbsDirectory),
                                   withIntermediateDirectories: true)
            try package.save(album)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return package
    }

    public static func open(_ url: URL) throws -> (ProjectPackage, Album) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectError.notAPackage
        }
        let package = ProjectPackage(url: url)
        guard FileManager.default.fileExists(atPath: package.albumURL.path) else {
            throw ProjectError.missingAlbumFile
        }
        let data: Data
        do { data = try Data(contentsOf: package.albumURL) } catch {
            throw ProjectError.corrupt(String(describing: error))
        }
        return (package, try package.migrate(data))
    }

    /// Writes `album.json` through a temporary file in the same directory; the old file survives
    /// any failure and no temporary file is left behind.
    public func save(_ album: Album) throws {
        let data = try AlbumCoding.encoder().encode(album)  // encoding fails before touching the disk
        try writeAtomically(data, to: albumURL)
    }

    // MARK: Migration

    private struct VersionProbe: Decodable { var formatVersion: Int }

    /// Decodes album JSON. Version 1 has no migrations: any `formatVersion` other than the current
    /// one (older or newer) throws `unsupportedVersion`.
    public func migrate(_ json: Data) throws -> Album {
        try Self.decodeAlbum(json)
    }

    /// `migrate` without a package: the app's `AlbumDocument` reads `album.json` from the
    /// `FileWrapper` it is handed before it knows the package URL.
    public static func decodeAlbum(_ json: Data) throws -> Album {
        let decoder = AlbumCoding.decoder()
        let version: Int
        do { version = try decoder.decode(VersionProbe.self, from: json).formatVersion } catch {
            throw ProjectError.corrupt(String(describing: error))
        }
        guard version == Album.currentFormatVersion else {
            throw ProjectError.unsupportedVersion(version)
        }
        do { return try decoder.decode(Album.self, from: json) } catch {
            throw ProjectError.corrupt(String(describing: error))
        }
    }

    // MARK: Originals

    /// Copies the original bytes into `originals/<id>.<ext>` atomically and returns the relative
    /// path to store in `OriginalState.stored(relativePath:)`.
    public func storeOriginal(data: Data, ext: String, for id: PhotoID) throws -> String {
        try Self.validate(id: id)
        let ext = ext.lowercased()
        try Self.validate(ext: ext)
        let relative = "\(Self.originalsDirectory)/\(id).\(ext)"
        try writeCoordinated(data, to: url.appendingPathComponent(relative))
        return relative
    }

    /// The stored original for a photo, or nil unless its state is `.stored`, the path stays
    /// inside the package and the file exists.
    public func originalURL(for id: PhotoID, album: Album) -> URL? {
        guard let photo = album.photos[id], case .stored(let relative) = photo.originalState,
              !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let candidate = url.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    // MARK: Thumbnails

    /// Stores an upright image as JPEG (quality 0.85), downscaled to at most 1024 px on the long
    /// side (never upscaled).
    public func storeThumbnail(_ image: CGImage, for id: PhotoID) throws {
        try Self.validate(id: id)
        let longSide = max(image.width, image.height)
        let scale = longSide > Self.thumbnailMaxPixelSize
            ? Double(Self.thumbnailMaxPixelSize) / Double(longSide) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ProjectError.writeFailed("cannot create thumbnail context")
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw ProjectError.writeFailed("cannot render thumbnail")
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProjectError.writeFailed("cannot create JPEG destination")
        }
        CGImageDestinationAddImage(destination, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectError.writeFailed("cannot encode thumbnail")
        }
        try writeCoordinated(buffer as Data, to: thumbnailURL(for: id))
    }

    /// The stored thumbnail, upright, or nil when missing or unreadable.
    public func thumbnail(for id: PhotoID) -> CGImage? {
        guard (try? Self.validate(id: id)) != nil,
              let source = CGImageSourceCreateWithURL(thumbnailURL(for: id) as CFURL, nil) else { return nil }
        return Self.decodeUpright(source, maxLongSide: Self.thumbnailMaxPixelSize)
    }

    /// The stored thumbnail downsampled while decoding so its long side is at most `maxPixelSize`
    /// (never upscaled), e.g. for a grid cell; nil when missing or unreadable. Thread-safe.
    public func thumbnail(for id: PhotoID, maxPixelSize: Int) -> CGImage? {
        guard (try? Self.validate(id: id)) != nil,
              let source = CGImageSourceCreateWithURL(thumbnailURL(for: id) as CFURL, nil) else { return nil }
        return Self.decodeUpright(source, maxLongSide: min(maxPixelSize, Self.thumbnailMaxPixelSize))
    }

    private func thumbnailURL(for id: PhotoID) -> URL {
        url.appendingPathComponent("\(Self.thumbsDirectory)/\(id).jpg")
    }

    // MARK: Helpers

    /// Decodes with EXIF orientation applied, scaled so the long side is at most `maxLongSide`
    /// (never upscaled). `shouldCache` is off so large originals do not stay in memory.
    static func decodeUpright(_ source: CGImageSource, maxLongSide: Int) -> CGImage? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxLongSide, max(w, h))),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func validate(id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.hasPrefix("."),
              !id.contains("/"), !id.contains("\\"), !id.contains("\0"), !id.contains(":") else {
            throw ProjectError.invalidName
        }
    }

    static func validate(ext: String) throws {
        guard (1...8).contains(ext.count),
              ext.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw ProjectError.invalidName
        }
    }

    /// Temp file next to the destination (same volume), then replace or move; the temp file is
    /// removed on failure.
    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: [])
            try Self.moveIntoPlace(temp, destination)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// An original or thumbnail: the bytes are staged in a temporary file OUTSIDE the package (an
    /// item replacement directory on the same volume, so the final step is a rename), then moved
    /// into place inside ONE `writeCoordinator` block on the destination URL. The slow part (writing
    /// possibly tens of MB) happens before the coordination, the block itself is quick, and the
    /// package never holds a half-written or temporary file that a document save could list. Falls
    /// back to a temporary file next to the destination when no replacement directory is available.
    /// The staging directory is removed afterwards, on success and on failure.
    private func writeCoordinated(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let staging = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: destination.deletingLastPathComponent(), create: true)
        let temp = (staging ?? destination.deletingLastPathComponent())
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        defer {
            try? fm.removeItem(at: temp)
            if let staging { try? fm.removeItem(at: staging) }
        }
        try data.write(to: temp, options: [])
        try writeCoordinator.coordinateWriting(at: destination) { [temp] target in
            try Self.moveIntoPlace(temp, target)
        }
    }

    private static func moveIntoPlace(_ temp: URL, _ destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }
}
