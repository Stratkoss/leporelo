import CoreGraphics
import Foundation
import ImageIO

/// Photo source over a folder of image files (recursive jpg/jpeg/heic/png).
///
/// - `identifier` is the path relative to the folder.
/// - Capture date: EXIF `DateTimeOriginal` (+ `SubsecTimeOriginal`). With `OffsetTimeOriginal`
///   the instant is exact and `timeZoneSeconds` is the offset. Without an offset the zone is
///   unknown: the naive time is interpreted in the Mac's CURRENT time zone as a last resort and
///   `timeZoneSeconds` is nil (day grouping infers zones from GPS neighbours).
///   No EXIF date: file creation date, else modification date; `timeZoneSeconds` nil.
/// - GPS (0,0) without any ref is treated as "no location".
/// - Date range queries are half-open: `start <= capturedAt < end`.
/// - Hidden entries (leading dot) and `*.leporelo` packages are ignored; unreadable files are skipped.
public struct FolderPhotoSource: PhotoSource {
    public let folder: URL

    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "heic", "png"]

    public init(folder: URL) {
        self.folder = folder
    }

    // MARK: PhotoSource

    public func albums() async throws -> [SourceAlbum] {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath()
        let children = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var result: [SourceAlbum] = []
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  child.pathExtension.lowercased() != "leporelo" else { continue }
            // Count only readable images (properties only, no pixel decode).
            let count = imageFiles(under: child).filter { readPhoto(at: $0, root: root) != nil }.count
            if count > 0 {
                result.append(SourceAlbum(identifier: child.lastPathComponent,
                                          name: child.lastPathComponent, count: count, isShared: false))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    public func photos(matching query: SourceQuery) async throws -> [SourcePhoto] {
        let root = folder.resolvingSymlinksInPath()
        let files: [URL]
        switch query {
        case .dateRange:
            files = imageFiles(under: root)
        case .album(let identifier, _):
            guard let dir = try? resolve(identifier), isDirectory(dir) else { return [] }
            files = imageFiles(under: dir)
        }
        var out: [SourcePhoto] = []
        for file in files {
            guard let photo = readPhoto(at: file, root: root) else { continue }
            if case .dateRange(let start, let end) = query,
               !(start <= photo.capturedAt && photo.capturedAt < end) { continue }
            out.append(photo)
        }
        return out.sorted { ($0.capturedAt, $0.identifier) < ($1.capturedAt, $1.identifier) }
    }

    public func thumbnail(for identifier: String, maxPixel: Int) async throws -> CGImage {
        let url = try resolve(identifier)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoSourceError.notFound(identifier)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw PhotoSourceError.notFound(identifier)
        }
        // ImageIO may upscale small images to maxPixel; never upscale.
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let (w, h) = uprightSize(props), max(w, h) < maxPixel,
           max(image.width, image.height) > max(w, h) {
            let noScale: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            ]
            if let exact = CGImageSourceCreateThumbnailAtIndex(src, 0, noScale as CFDictionary) {
                image = exact
            }
        }
        return image
    }

    public func original(for identifier: String) async throws -> (data: Data, ext: String) {
        let url = try resolve(identifier)
        guard let data = try? Data(contentsOf: url) else {
            throw PhotoSourceError.notFound(identifier)
        }
        return (data, url.pathExtension.lowercased())
    }

    // MARK: Path safety

    /// Resolves `identifier` relative to the folder; rejects absolute paths, `..` traversal and
    /// symlinks that escape the folder. The target must exist.
    func resolve(_ identifier: String) throws -> URL {
        let components = identifier.split(separator: "/", omittingEmptySubsequences: true)
        guard !identifier.hasPrefix("/"), !identifier.hasPrefix("~"), !components.isEmpty,
              !components.contains("..") else {
            throw PhotoSourceError.notFound(identifier)
        }
        let root = folder.resolvingSymlinksInPath()
        let candidate = components.reduce(root) { $0.appendingPathComponent(String($1)) }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw PhotoSourceError.notFound(identifier)
        }
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw PhotoSourceError.notFound(identifier)
        }
        return resolved
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: Enumeration

    /// Supported, non-hidden image files below `dir` (symlinks resolved; escaping ones dropped).
    private func imageFiles(under dir: URL) -> [URL] {
        let root = folder.resolvingSymlinksInPath()
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if url.pathExtension.lowercased() == "leporelo" { en.skipDescendants() }
                continue
            }
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: Metadata

    private func readPhoto(at url: URL, root: URL) -> SourcePhoto? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, options as CFDictionary)
                as? [CFString: Any],
              let (w, h) = uprightSize(props) else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let (date, zone) = capture(exif: exif, url: url)
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        // Resolve only the parent so symlinked files keep their own name, and so /var vs
        // /private/var spellings of the same directory compare equal.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let rootPath = root.path
        var relative = url.lastPathComponent
        if parent.hasPrefix(rootPath + "/") {
            relative = String(parent.dropFirst(rootPath.count + 1)) + "/" + relative
        }
        return SourcePhoto(identifier: relative, capturedAt: date, timeZoneSeconds: zone,
                           location: location(gps: gps), pixelWidth: w, pixelHeight: h,
                           kind: .photo, isCloudOnly: false)
    }

    /// Upright pixel size: orientations 5-8 swap width and height.
    private func uprightSize(_ props: [CFString: Any]) -> (Int, Int)? {
        guard let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }

    private func capture(exif: [CFString: Any]?, url: URL) -> (Date, Int?) {
        if let exif, let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let naive = Self.parseNaive(text) {
            var fraction = 0.0
            if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
               !sub.isEmpty, sub.allSatisfy(\.isNumber), let v = Double("0." + sub) {
                fraction = v
            }
            let offsetText = (exif["OffsetTimeOriginal" as CFString] as? String)
            if let offsetText, let offset = Self.parseOffset(offsetText) {
                let instant = Self.utcCalendar.date(from: naive)!
                    .addingTimeInterval(-Double(offset) + fraction)
                return (instant, offset)
            }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            if let local = cal.date(from: naive) {
                return (local.addingTimeInterval(fraction), nil)
            }
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values?.creationDate ?? values?.contentModificationDate ?? Date(timeIntervalSince1970: 0), nil)
    }

    private func location(gps: [CFString: Any]?) -> GeoPoint? {
        guard let gps,
              let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        if lat == 0, lon == 0, latRef == nil, lonRef == nil { return nil }
        let latitude = latRef?.uppercased() == "S" ? -abs(lat) : lat
        let longitude = lonRef?.uppercased() == "W" ? -abs(lon) : lon
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// "yyyy:MM:dd HH:mm:ss" -> components.
    private static func parseNaive(_ s: String) -> DateComponents? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2],
                              hour: parts[3], minute: parts[4], second: parts[5])
    }

    /// "+02:00" / "-0530" / "Z" -> seconds.
    private static func parseOffset(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "Z" { return 0 }
        guard let first = t.first, first == "+" || first == "-" else { return nil }
        let digits = t.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)),
              hh <= 14, mm < 60 else { return nil }
        return (first == "-" ? -1 : 1) * (hh * 3600 + mm * 60)
    }
}
