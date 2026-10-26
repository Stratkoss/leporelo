import CoreGraphics
import Foundation

public enum Sharpness {
    /// Variance of the 3x3 (4-neighbour) Laplacian over an 8-bit grayscale rendering of the
    /// image, downscaled so the longer side is at most `maxSide`. Higher means sharper.
    public static func laplacianVariance(_ image: CGImage, maxSide: Int = 512) -> Double {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return 0 }
        let scale = min(1.0, Double(maxSide) / Double(longest))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard w >= 3, h >= 3 else { return 0 }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var sum = 0.0
        var sumSq = 0.0
        var count = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = 4 * Int(pixels[i]) - Int(pixels[i - 1]) - Int(pixels[i + 1])
                    - Int(pixels[i - w]) - Int(pixels[i + w])
                let d = Double(l)
                sum += d
                sumSq += d * d
                count += 1
            }
        }
        let mean = sum / count
        return max(0, sumSq / count - mean * mean)
    }
}
