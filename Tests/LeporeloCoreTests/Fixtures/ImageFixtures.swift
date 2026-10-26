import CoreGraphics
import CoreImage
import Foundation

/// Synthetic images shared by analysis, render, export and pipeline tests.
enum ImageFixtures {
    static let colorSpace = CGColorSpaceCreateDeviceRGB()

    private static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Black/white checkerboard, square image, `cell`-pixel squares.
    static func checkerboard(size: Int = 256, cell: Int = 8) -> CGImage {
        let ctx = context(width: size, height: size)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let n = (size + cell - 1) / cell
        for row in 0..<n {
            for col in 0..<n where (row + col) % 2 == 0 {
                ctx.fill(CGRect(x: col * cell, y: row * cell, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    /// Gaussian blur (CIGaussianBlur), edges clamped, cropped to the original extent.
    static func blurred(_ image: CGImage, radius: Double = 8) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        let ci = CIContext(options: [.useSoftwareRenderer: true])
        return ci.createCGImage(output, from: input.extent)!
    }

    /// Uniform colour image.
    static func solid(color: CGColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                      width: Int = 256, height: Int = 256) -> CGImage {
        let ctx = context(width: width, height: height)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
