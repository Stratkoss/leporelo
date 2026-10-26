import CoreGraphics
import Foundation
import Vision

/// On-device analysis (Vision, macOS 15 Swift API). No network.
///
/// Failure policy: if any Vision request throws, `analyze` throws; a partial result would be
/// indistinguishable from "no faces / no aesthetics" and silently skew scoring.
public struct ImageAnalyzer: Sendable {
    public init() {}

    public func analyze(_ image: CGImage) async throws -> PhotoAnalysis {
        let aesthetics = try await CalculateImageAestheticsScoresRequest().perform(on: image)
        let featurePrint = try await GenerateImageFeaturePrintRequest().perform(on: image)
        let faces = try await DetectFaceLandmarksRequest().perform(on: image)

        var faceRects: [Rect] = []
        var closedEyes = false
        for face in faces {
            // Vision: normalised, origin bottom-left. Model: origin top-left.
            let b = face.boundingBox.cgRect
            faceRects.append(Rect(x: Double(b.minX), y: 1 - Double(b.maxY),
                                  width: Double(b.width), height: Double(b.height)))
            if let landmarks = face.landmarks {
                for eye in [landmarks.leftEye, landmarks.rightEye] {
                    if Self.isClosed(eye.points.map { Point(x: Double($0.x), y: Double($0.y)) }) {
                        closedEyes = true
                    }
                }
            }
        }

        let aesthetic = min(1, max(0, (Double(aesthetics.overallScore) + 1) / 2))
        return PhotoAnalysis(aesthetic: aesthetic,
                             sharpness: Sharpness.laplacianVariance(image),
                             isUtility: aesthetics.isUtility,
                             faceRects: faceRects,
                             closedEyes: closedEyes,
                             featurePrint: featurePrint.data)
    }

    /// Splits an eye contour into upper/lower lid by the vertical midpoint of its extent.
    static func isClosed(_ points: [Point]) -> Bool {
        guard points.count >= 4,
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return false }
        let mid = (minY + maxY) / 2
        let upper = points.filter { $0.y > mid }
        let lower = points.filter { $0.y <= mid }
        // Corner points sit on the midline; keep them in the lower set (they only affect width).
        guard !upper.isEmpty, !lower.isEmpty else { return true }
        return EyeAspectRatio.ratio(upper: upper, lower: lower) < EyeAspectRatio.closedThreshold
    }
}

public enum FeaturePrintDistance {
    /// Own L2 distance over the Float32 elements of two `FeaturePrintObservation.data` blobs.
    /// Chosen over reconstructing a `FeaturePrintObservation` because that type has no public
    /// initialiser from raw data (only Codable / VN bridging). Identical data gives 0;
    /// mismatched or empty inputs give `.infinity`.
    public static func distance(_ a: Data, _ b: Data) -> Float {
        let size = MemoryLayout<Float>.size
        guard a.count == b.count, a.count >= size, a.count % size == 0 else { return .infinity }
        let n = a.count / size
        var sum: Float = 0
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                for i in 0..<n {
                    let x = pa.loadUnaligned(fromByteOffset: i * size, as: Float.self)
                    let y = pb.loadUnaligned(fromByteOffset: i * size, as: Float.self)
                    let d = x - y
                    sum += d * d
                }
            }
        }
        return sum.squareRoot()
    }
}
