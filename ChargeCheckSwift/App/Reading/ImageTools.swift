import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit

extension UIImage {
    /// Upright copy, no larger than `maxSide` on its long edge. `quarterTurns` rotates it clockwise.
    func prepared(maxSide: CGFloat = 2600, quarterTurns: Int = 0) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return self }
        let scale = min(1, maxSide / longest)
        let base = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let turns = ((quarterTurns % 4) + 4) % 4
        let canvas = turns % 2 == 0 ? base : CGSize(width: base.height, height: base.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            let cg = context.cgContext
            cg.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            cg.rotate(by: CGFloat(turns) * .pi / 2)
            draw(in: CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height))
        }
    }

    /// A black-and-white, higher-contrast copy: a different view of the same photo for the double check.
    func highContrast() -> CGImage? {
        guard let input = cgImage else { return nil }
        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cgImage: input)
        filter.saturation = 0
        filter.contrast = 1.45
        filter.brightness = 0.02
        guard let output = filter.outputImage else { return input }
        return ImageTools.context.createCGImage(output, from: output.extent) ?? input
    }

    func thumbnail(side: CGFloat = 120) -> UIImage {
        prepared(maxSide: side)
    }
}

enum ImageTools {
    static let context = CIContext()

    /// Each page of a PDF as a picture (up to `maxPages`).
    static func pages(ofPDF url: URL, maxPages: Int = 10) -> [UIImage] {
        guard let document = PDFDocument(url: url) else { return [] }
        var images: [UIImage] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let longest = max(bounds.width, bounds.height)
            guard longest > 0 else { continue }
            let scale = min(4, 2400 / longest)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let picture = page.thumbnail(of: size, for: .mediaBox)
            // put it on white: PDF pages can have a clear background
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let flat = UIGraphicsImageRenderer(size: picture.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: picture.size))
                picture.draw(at: .zero)
            }
            images.append(flat)
        }
        return images
    }
}

/// Why a photo might have been hard to read. Only used to word the "couldn't read" message.
enum PhotoProblem {
    case dark
    case blurry
}

extension ImageTools {
    /// A quick look at a photo: is it too dark, or blurry? Works on a small grey copy, so it is fast.
    static func problem(with image: UIImage) -> PhotoProblem? {
        guard let picture = image.cgImage, picture.width > 0, picture.height > 0 else { return nil }
        let width = 256
        let height = max(16, min(1024, Int(Double(width) * Double(picture.height) / Double(picture.width))))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let grey = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            grey.interpolationQuality = .medium
            grey.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let brightness = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        if brightness < 70 { return .dark }
        // sharpness: how sharply each pixel differs from its neighbours (the spread of the Laplacian)
        var sum = 0.0, sumOfSquares = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let edge = 4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - width]) - Double(pixels[i + width])
                sum += edge
                sumOfSquares += edge * edge
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let spread = sumOfSquares / count - (sum / count) * (sum / count)
        return spread < 60 ? .blurry : nil
    }
}
