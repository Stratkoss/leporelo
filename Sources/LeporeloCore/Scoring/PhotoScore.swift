import Foundation

public enum PhotoScore {
    /// Laplacian variance regarded as fully sharp (calibrated in Task 6).
    /// Measured (maxSide 512): 256px checkerboard (8px cells) = 39493, same blurred (radius 8) = 0.09.
    /// The synthetic checkerboard is an extreme upper bound (maximal edges), not a photo; real
    /// photos fall in the ~10...1000 range, so 100 is kept (needs tuning on real photos).
    public static let sharpnessReference: Double = 100
    public static let defectiveSharpness: Double = 15
    public static let unanalysedScore: Double = 0.5
    public static let aestheticWeight: Double = 0.6
    public static let sharpnessWeight: Double = 0.4
    public static let closedEyesPenalty: Double = 0.3
    public static let excludedScore: Double = -1

    public static func score(_ photo: Photo) -> Double {
        if photo.kind == .video { return excludedScore }
        guard let a = photo.analysis else { return unanalysedScore }
        if a.isUtility { return excludedScore }
        var s = aestheticWeight * a.aesthetic + sharpnessWeight * min(a.sharpness / sharpnessReference, 1)
        if a.closedEyes { s -= closedEyesPenalty }
        return s
    }

    public static func isDefective(_ photo: Photo) -> Bool {
        guard let a = photo.analysis else { return false }
        return a.sharpness < defectiveSharpness || a.isUtility || a.closedEyes
    }
}
