import UIKit

enum ReaderSmartBackground {
    static func color(for image: UIImage) -> UIColor {
        guard let cgImage = image.cgImage else { return .black }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return .black }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            // Use the dominant edge color; artwork in the middle must not tint white margins.
            var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
            for y in 0..<side {
                for x in 0..<side where x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                    let offset = (y * side + x) * 4, alpha = Int(buffer[offset + 3])
                    guard alpha >= 128 else { continue }
                    let r = min(255, Int(buffer[offset]) * 255 / alpha)
                    let g = min(255, Int(buffer[offset + 1]) * 255 / alpha)
                    let b = min(255, Int(buffer[offset + 2]) * 255 / alpha)
                    let key = (r / 32) << 6 | (g / 32) << 3 | (b / 32)
                    let old = buckets[key] ?? (0, 0, 0, 0)
                    buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
                }
            }
            guard let winner = buckets.sorted(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }).first?.value else { return .black }
            let divisor = CGFloat(winner.count * 255)
            return UIColor(red: CGFloat(winner.r) / divisor, green: CGFloat(winner.g) / divisor, blue: CGFloat(winner.b) / divisor, alpha: 1)
        }
    }

    static func isLight(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return r * 0.2126 + g * 0.7152 + b * 0.0722 > 0.5
    }
}
