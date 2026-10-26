import Foundation

public enum EyeAspectRatio {
    /// Below this ratio an eye counts as closed.
    public static let closedThreshold = 0.2

    /// Eye openness: mean vertical distance between the upper and lower lid points divided by
    /// the horizontal extent of all points. Orientation-agnostic (uses the absolute gap).
    public static func ratio(upper: [Point], lower: [Point]) -> Double {
        guard !upper.isEmpty, !lower.isEmpty else { return 0 }
        let all = upper + lower
        let width = (all.map(\.x).max() ?? 0) - (all.map(\.x).min() ?? 0)
        guard width > 0 else { return 0 }
        let upperY = upper.map(\.y).reduce(0, +) / Double(upper.count)
        let lowerY = lower.map(\.y).reduce(0, +) / Double(lower.count)
        return abs(upperY - lowerY) / width
    }
}
