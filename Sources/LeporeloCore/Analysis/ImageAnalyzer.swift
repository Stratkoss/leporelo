import CoreGraphics
import Foundation
import Vision

/// On-device analysis (Vision, macOS 15 Swift API). No network.
///
/// Failure policy: if any Vision request throws, `analyze` throws; a partial result would be
/// indistinguishable from "no faces / no aesthetics" and silently skew scoring.
public enum AnalysisError: Error, Sendable { case unsupportedFeaturePrintType }

public struct ImageAnalyzer: Sendable {
    public init() {}

    public func analyze(_ image: CGImage) async throws -> PhotoAnalysis {
        let aesthetics = try await CalculateImageAestheticsScoresRequest().perform(on: image)
        let featurePrint = try await GenerateImageFeaturePrintRequest().perform(on: image)
        guard featurePrint.elementType == .float else { throw AnalysisError.unsupportedFeaturePrintType }
        let faces = try await DetectFaceLandmarksRequest().perform(on: image)

        var faceRects: [Rect] = []
        var closedEyes = false
        for face in faces {
            // Vision: normalised, origin bottom-left. Model: origin top-left.
            let b = face.boundingBox.cgRect
            faceRects.append(Rect(x: Double(b.minX), y: 1 - Double(b.maxY),
                                  width: Double(b.width), height: Double(b.height)))
            if let landmarks = face.landmarks {
                let faceSize = Size(width: Double(b.width) * Double(image.width),
                                    height: Double(b.height) * Double(image.height))
                for eye in [landmarks.leftEye, landmarks.rightEye] {
                    if Self.isClosed(eye.points.map { Point(x: Double($0.x), y: Double($0.y)) },
                                     faceSize: faceSize) {
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

    /// Closed-eye test for one eye contour. `points` are Vision landmark points, normalised to the
    /// face bounding box; `faceSize` is that box in pixels, used to bring x and y to a common scale
    /// before measuring (otherwise a non-square face box distorts the ratio).
    ///
    /// The eye axis is the line through the two points farthest apart (the lid corners), so a tilted
    /// head does not matter. Openness = (largest offset above the axis + largest below) / eye width.
    static func isClosed(_ points: [Point], faceSize: Size) -> Bool {
        guard let openness = openness(points, faceSize: faceSize) else { return false }
        return openness < EyeAspectRatio.closedThreshold
    }

    static func openness(_ points: [Point], faceSize: Size) -> Double? {
        guard points.count >= 4 else { return nil }
        let scaled = points.map { Point(x: $0.x * faceSize.width, y: $0.y * faceSize.height) }
        // Lid corners = the two points farthest apart (robust to steep head tilt).
        var c1 = scaled[0], c2 = scaled[1], best = -1.0
        for i in 0..<scaled.count {
            for j in (i + 1)..<scaled.count {
                let dx = scaled[i].x - scaled[j].x, dy = scaled[i].y - scaled[j].y
                if dx * dx + dy * dy > best { best = dx * dx + dy * dy; c1 = scaled[i]; c2 = scaled[j] }
            }
        }
        let ux = c2.x - c1.x, uy = c2.y - c1.y
        let width = (ux * ux + uy * uy).squareRoot()
        guard width > 0 else { return nil }
        var above = 0.0, below = 0.0
        for p in scaled {
            // Signed perpendicular distance from the corner-to-corner axis.
            let d = (ux * (p.y - c1.y) - uy * (p.x - c1.x)) / width
            above = max(above, d)
            below = max(below, -d)
        }
        return (above + below) / width
    }
}

public enum FeaturePrintDistance {
    /// Own L2 distance over the Float32 elements (ImageAnalyzer rejects non-`.float` prints, so stored data is Float32) of two `FeaturePrintObservation.data` blobs.
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
