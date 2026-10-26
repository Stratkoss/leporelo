import CoreGraphics
import Foundation
import Testing
@testable import LeporeloCore

@Suite struct AnalysisTests {
    @Test func sharpImageScoresHigherThanBlurred() {
        let sharp = ImageFixtures.checkerboard(size: 256)
        let blurred = ImageFixtures.blurred(sharp, radius: 8)
        let s = Sharpness.laplacianVariance(sharp)
        let b = Sharpness.laplacianVariance(blurred)
        #expect(s > b * 5)
    }

    @Test func solidImageSharpnessNearZero() {
        #expect(Sharpness.laplacianVariance(ImageFixtures.solid()) < 1)
    }

    @Test func eyeRatioOpenVsClosed() {
        // Eye width 1.0 (x 0...1); open: gap 0.35, closed: gap 0.1.
        func eye(gap: Double) -> Double {
            EyeAspectRatio.ratio(
                upper: [Point(x: 0, y: 0.5 + gap / 2), Point(x: 1, y: 0.5 + gap / 2)],
                lower: [Point(x: 0, y: 0.5 - gap / 2), Point(x: 1, y: 0.5 - gap / 2)])
        }
        let open = eye(gap: 0.35)
        let closed = eye(gap: 0.1)
        #expect(abs(open - 0.35) < 0.01)
        #expect(abs(closed - 0.1) < 0.01)
        #expect(open > EyeAspectRatio.closedThreshold)
        #expect(closed < EyeAspectRatio.closedThreshold)
    }

    @Test func analyzerReturnsRangesOnFixture() async throws {
        let result = try await ImageAnalyzer().analyze(ImageFixtures.checkerboard(size: 256))
        #expect((0...1).contains(result.aesthetic))
        #expect(result.faceRects.isEmpty)
        #expect(result.closedEyes == false)
        #expect(result.sharpness > 0)
        #expect((result.featurePrint?.count ?? 0) > 0)
    }

    @Test func featurePrintDistanceSelfIsZero() async throws {
        let analyzer = ImageAnalyzer()
        let fp = try #require(try await analyzer.analyze(ImageFixtures.checkerboard(size: 256)).featurePrint)
        #expect(FeaturePrintDistance.distance(fp, fp) == 0)
        let other = try #require(try await analyzer.analyze(ImageFixtures.solid()).featurePrint)
        #expect(FeaturePrintDistance.distance(fp, other) > 0)
    }

    // Eye contour in a local frame (width 1, half-gap h above and below), rotated by `angle`,
    // placed in a face box of the given pixel size (landmarks are normalised to that box).
    private func contour(halfGap h: Double, angle: Double, face: Size) -> [Point] {
        let local = [(0.0, 0.0), (0.25, h), (0.5, h * 1.1), (0.75, h), (1.0, 0.0),
                     (0.75, -h * 0.8), (0.5, -h * 0.9), (0.25, -h * 0.8)]
        let eyeW = 0.2 * face.width // eye width in pixels
        return local.map { (x, y) in
            let px = (x - 0.5) * eyeW, py = y * eyeW
            let rx = px * cos(angle) - py * sin(angle), ry = px * sin(angle) + py * cos(angle)
            return Point(x: (0.5 * face.width + rx) / face.width, y: (0.5 * face.height + ry) / face.height)
        }
    }

    @Test func openEyeNotFlaggedClosedEvenTiltedOrNonSquareFace() {
        for face in [Size(width: 400, height: 400), Size(width: 300, height: 500)] {
            for angle in [0.0, 0.5, -0.6, 1.2] {
                let pts = contour(halfGap: 0.17, angle: angle, face: face)
                let o = ImageAnalyzer.openness(pts, faceSize: face)!
                #expect(o > 0.3 && o < 0.4, "openness \(o)")
                #expect(!ImageAnalyzer.isClosed(pts, faceSize: face))
            }
        }
    }

    @Test func closedEyeFlaggedEvenTilted() {
        for face in [Size(width: 400, height: 400), Size(width: 300, height: 500)] {
            for angle in [0.0, 0.5, -0.6, 1.2] {
                let pts = contour(halfGap: 0.03, angle: angle, face: face)
                #expect(ImageAnalyzer.isClosed(pts, faceSize: face))
            }
        }
    }

    @Test func degenerateContourIsNotClosed() {
        #expect(!ImageAnalyzer.isClosed([Point(x: 0, y: 0)], faceSize: Size(width: 10, height: 10)))
    }
}
