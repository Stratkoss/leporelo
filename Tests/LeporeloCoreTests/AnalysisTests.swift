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
        print("MEASURED sharpness checkerboard=\(s) blurred=\(b)")
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
}
