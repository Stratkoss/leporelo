import Foundation

public struct BookFormat: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var pageWidthMM: Double
    public var pageHeightMM: Double

    public init(id: String, name: String, pageWidthMM: Double, pageHeightMM: Double) {
        self.id = id
        self.name = name
        self.pageWidthMM = pageWidthMM
        self.pageHeightMM = pageHeightMM
    }
}

public enum PageMode: String, Sendable, Codable, Equatable {
    case singlePages, spreads
}

public enum CoverMode: String, Sendable, Codable, Equatable {
    case frontOnly, wrapWithSpine, none
}

public struct PageCountRule: Sendable, Codable, Equatable {
    public var min: Int
    public var max: Int?
    public var multipleOf: Int

    public init(min: Int, max: Int?, multipleOf: Int) {
        self.min = min
        self.max = max
        self.multipleOf = multipleOf
    }

    public func isSatisfied(by pages: Int) -> Bool {
        guard pages >= min else { return false }
        if let max, pages > max { return false }
        return multipleOf <= 1 || pages % multipleOf == 0
    }

    /// Smallest page count >= `pages` that meets min and multipleOf (max is not enforced here).
    public func nextValid(atLeast pages: Int) -> Int {
        let n = Swift.max(pages, min)
        guard multipleOf > 1 else { return n }
        let rem = n % multipleOf
        return rem == 0 ? n : n + (multipleOf - rem)
    }
}

public struct OutputSpec: Sendable, Codable, Equatable {
    public var fileType: String
    public var dpi: Int
    public var jpegQuality: Double
    public var separateCover: Bool

    public init(fileType: String, dpi: Int, jpegQuality: Double, separateCover: Bool) {
        self.fileType = fileType
        self.dpi = dpi
        self.jpegQuality = jpegQuality
        self.separateCover = separateCover
    }
}

public struct SupplierProfile: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var formats: [BookFormat]
    public var pageMode: PageMode
    public var coverMode: CoverMode
    public var pageCount: PageCountRule
    public var bleedMM: Double
    public var safeMM: Double
    public var output: OutputSpec
    public var verified: Bool
    public var sourceURL: String
    public var uploadSteps: [String]

    public init(id: String, name: String, formats: [BookFormat], pageMode: PageMode,
                coverMode: CoverMode, pageCount: PageCountRule, bleedMM: Double, safeMM: Double,
                output: OutputSpec, verified: Bool, sourceURL: String, uploadSteps: [String]) {
        self.id = id
        self.name = name
        self.formats = formats
        self.pageMode = pageMode
        self.coverMode = coverMode
        self.pageCount = pageCount
        self.bleedMM = bleedMM
        self.safeMM = safeMM
        self.output = output
        self.verified = verified
        self.sourceURL = sourceURL
        self.uploadSteps = uploadSteps
    }
}

public enum PageSide: Sendable, Equatable {
    case left, right
}

public struct PageGeometry: Sendable {
    public let format: BookFormat
    public let profile: SupplierProfile

    public init(format: BookFormat, profile: SupplierProfile) {
        self.format = format
        self.profile = profile
    }

    public var spreadSize: Size {
        Size(width: 2 * format.pageWidthMM, height: format.pageHeightMM)
    }

    public func pageRect(side: PageSide) -> Rect {
        let w = format.pageWidthMM
        return Rect(x: side == .left ? 0 : w, y: 0, width: w, height: format.pageHeightMM)
    }

    public func bleedRect(side: PageSide) -> Rect {
        let page = pageRect(side: side)
        let b = profile.bleedMM
        switch profile.pageMode {
        case .singlePages:
            return Rect(x: page.minX - b, y: -b, width: page.size.width + 2 * b, height: page.size.height + 2 * b)
        case .spreads:
            // No bleed at the spine.
            let minX = side == .left ? page.minX - b : page.minX
            let maxX = side == .left ? page.maxX : page.maxX + b
            return Rect(x: minX, y: -b, width: maxX - minX, height: page.size.height + 2 * b)
        }
    }

    public func safeRect(side: PageSide) -> Rect {
        pageRect(side: side).insetBy(profile.safeMM)
    }

    public var spreadBleedRect: Rect {
        let b = profile.bleedMM
        return Rect(x: -b, y: -b, width: spreadSize.width + 2 * b, height: spreadSize.height + 2 * b)
    }
}
