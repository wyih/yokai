import SwiftUI

struct ReaderAppearance {
    static func color(_ name: String) -> Color {
        switch name { case "gray": Color(white: 0.15); case "paper": Color(red: 0.95, green: 0.92, blue: 0.85); case "white": .white; default: .black }
    }
}

struct AutoScrollDriver: UIViewRepresentable {
    let enabled: Bool
    let speed: Double
    var scrollRequest = 0
    var onBoundary: ((Int) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(scrollRequest: scrollRequest) }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.scrollRequest != scrollRequest {
            let delta = scrollRequest - context.coordinator.scrollRequest
            context.coordinator.scrollRequest = scrollRequest
            DispatchQueue.main.async { [weak view] in
                var ancestor = view?.superview
                while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
                guard let scroll = ancestor as? UIScrollView else { return }
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-YokaiReaderTrace") {
                    FileHandle.standardError.write(Data("Reader scroll delta \(delta) offset \(scroll.contentOffset) size \(scroll.contentSize) bounds \(scroll.bounds.size)\n".utf8))
                }
                #endif
                let start = -scroll.adjustedContentInset.top
                let end = max(start, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                if delta > 0 && scroll.contentOffset.y >= end - 1 { onBoundary?(1); return }
                if delta < 0 && scroll.contentOffset.y <= start + 1 { onBoundary?(-1); return }
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(end, max(start, scroll.contentOffset.y + CGFloat(delta) * scroll.bounds.height * 0.75))), animated: true)
            }
        }
        context.coordinator.speed = speed
        context.coordinator.timer?.invalidate(); context.coordinator.timer = nil
        guard enabled else { return }
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak view, weak coordinator = context.coordinator] _ in
            var ancestor = view?.superview
            while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
            guard let scroll = ancestor as? UIScrollView, let coordinator, !scroll.isDragging, !scroll.isDecelerating else { return }
            let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            if scroll.contentOffset.y >= end - 1 {
                if !coordinator.reachedEnd { coordinator.reachedEnd = true; onBoundary?(1) }
            } else {
                coordinator.reachedEnd = false
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(end, scroll.contentOffset.y + coordinator.speed / 30)), animated: false)
            }
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.timer?.invalidate() }
    final class Coordinator {
        var timer: Timer?
        var speed = 40.0
        var scrollRequest: Int
        var reachedEnd = false
        init(scrollRequest: Int) { self.scrollRequest = scrollRequest }
    }
}

struct ReaderImageFilter: ViewModifier {
    let grayscale: Bool
    let inverted: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if inverted { content.saturation(grayscale ? 0 : 1).colorInvert() }
        else { content.saturation(grayscale ? 0 : 1) }
    }
}

extension UIImage {
    func spreadHalf(_ half: Int) -> UIImage {
        guard let source = cgImage, source.width > source.height else { return self }
        let midpoint = source.width / 2
        let area = CGRect(x: half == 0 ? 0 : midpoint, y: 0,
                          width: half == 0 ? midpoint : source.width - midpoint, height: source.height)
        guard let image = source.cropping(to: area) else { return self }
        return UIImage(cgImage: image, scale: scale, orientation: imageOrientation)
    }
    func stackingSpread(rightFirst: Bool, gap: CGFloat) -> UIImage {
        guard let source = cgImage, source.width > source.height else { return self }
        let first = spreadHalf(rightFirst ? 1 : 0), second = spreadHalf(rightFirst ? 0 : 1)
        let width = CGFloat(source.width / 2), height = CGFloat(source.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height * 2 + gap), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height * 2 + gap))
            first.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            second.draw(in: CGRect(x: 0, y: height + gap, width: width, height: height))
        }
    }
    func trimmingBorders() -> UIImage {
        guard let original = cgImage else { return self }
        let factor = min(1.0, 256.0 / Double(max(original.width, original.height)))
        let width = max(1, Int(Double(original.width) * factor)), height = max(1, Int(Double(original.height) * factor))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let crop: CGRect? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            func isBorder(_ x: Int, _ y: Int) -> Bool {
                let i = (y * width + x) * 4
                return (bytes[i] > 244 && bytes[i+1] > 244 && bytes[i+2] > 244) || (bytes[i] < 11 && bytes[i+1] < 11 && bytes[i+2] < 11)
            }
            func row(_ y: Int) -> Bool { (0..<width).filter { isBorder($0, y) }.count >= Int(Double(width) * 0.98) }
            func column(_ x: Int) -> Bool { (0..<height).filter { isBorder(x, $0) }.count >= Int(Double(height) * 0.98) }
            var left = 0, right = width - 1, top = 0, bottom = height - 1
            while left < width / 4 && column(left) { left += 1 }
            while right > width * 3 / 4 && column(right) { right -= 1 }
            while top < height / 4 && row(top) { top += 1 }
            while bottom > height * 3 / 4 && row(bottom) { bottom -= 1 }
            let sx = CGFloat(original.width) / CGFloat(width), sy = CGFloat(original.height) / CGFloat(height)
            return CGRect(x: CGFloat(left) * sx, y: CGFloat(top) * sy, width: CGFloat(right - left + 1) * sx, height: CGFloat(bottom - top + 1) * sy).integral
        }
        guard let crop, let trimmed = original.cropping(to: crop) else { return self }
        return UIImage(cgImage: trimmed, scale: scale, orientation: imageOrientation)
    }
}
