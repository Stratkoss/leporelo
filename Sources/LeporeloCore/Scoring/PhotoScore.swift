import Foundation

public enum PhotoScore {
    /// Laplacian variance regarded as fully sharp (calibrated in Task 6 on system images).
    /// Measured with Sharpness.laplacianVariance (maxSide 512); blur radii are 4 / 8 px at 512-px scale:
    ///   Tree 995 (blur 10 / 2.5), The Beach 2912 (23 / 3.9), Catalina Coast 1133 (3.5 / 1.9),
    ///   The Cliffs 3395 (19 / 3.4), Valley Light 592 (2.6 / 1.7),
    ///   DefaultDesktop 698 (1.7 / 1.4), Sonoma 19.5 (smooth gradient scene; 1.7 / 1.6).
    /// Sharp detailed images: ~600-3400; blurred: ~1.4-23. Synthetic checkerboard: 39493 (not representative).
    /// 500 sits near the lower end of detailed sharp images. defectiveSharpness 15 sits inside the
    /// blurred range (catches clear blur, mildly blurred up to ~23 may pass).
    public static let sharpnessReference: Double = 500
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
