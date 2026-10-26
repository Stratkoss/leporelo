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

    /// A synthetic "photo": a smooth two-colour gradient (hue from `seed`) with a few hard-edged
    /// bands, so it encodes small and fast as JPEG but is not flagged as blurred (a pure gradient
    /// has a Laplacian variance far below `PhotoScore.defectiveSharpness`).
    static func scene(seed: Int, width: Int, height: Int) -> CGImage {
        let ctx = context(width: width, height: height)
        let hue = Double((seed * 37) % 360) / 360
        func color(_ h: Double, _ b: Double) -> CGColor {
            let c = HSB.rgb(hue: h.truncatingRemainder(dividingBy: 1), brightness: b)
            return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        let gradient = CGGradient(colorsSpace: colorSpace,
                                  colors: [color(hue, 0.9), color(hue + 0.3, 0.4)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let band = max(4, width / 40)
        ctx.setFillColor(color(hue + 0.5, 0.15))
        for i in 0..<6 {
            let x = (i * 2 + seed % 3) * width / 14
            ctx.fill(CGRect(x: x, y: 0, width: band, height: height))
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for i in 0..<4 {
            let y = (i * 2 + 1 + seed % 2) * height / 10
            ctx.fill(CGRect(x: 0, y: y, width: width, height: band / 2))
        }
        return ctx.makeImage()!
    }
}

/// HSB -> RGB without AppKit.
private enum HSB {
    static func rgb(hue: Double, brightness v: Double, saturation s: Double = 0.7) -> (Double, Double, Double) {
        let h = hue * 6, i = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
