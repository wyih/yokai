import SwiftUI

struct ReaderAppearance {
    static func color(_ name: String) -> Color {
        switch name { case "gray": Color(white: 0.15); case "paper": Color(red: 0.95, green: 0.92, blue: 0.85); case "white": .white; default: .black }
    }
}

enum ReaderToolbarItem: String, CaseIterable, Identifiable {
    case bookmark, autoScroll, trimBorders, readingMode, pageLayout, background, tapZones
    static let defaults = "bookmark,autoScroll,trimBorders,readingMode"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bookmark: "书签"
        case .autoScroll: "自动滚动"
        case .trimBorders: "裁剪边框"
        case .readingMode: "阅读方式"
        case .pageLayout: "页面布局"
        case .background: "阅读背景"
        case .tapZones: "点按区域"
        }
    }
    var symbol: String {
        switch self {
        case .bookmark: "bookmark"
        case .autoScroll: "play"
        case .trimBorders: "crop"
        case .readingMode: "arrow.left.arrow.right"
        case .pageLayout: "rectangle.split.2x1"
        case .background: "circle.lefthalf.filled"
        case .tapZones: "hand.tap"
        }
    }
    static func items(from raw: String) -> [Self] {
        var seen = Set<Self>()
        return raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }
}

struct ReaderControlSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

enum ReaderScrollSpeed {
    static func adjusted(start: Double, translation: CGFloat) -> Double {
        min(150, max(10, start - Double(translation) * 0.4))
    }
}

struct AutoScrollDriver: UIViewRepresentable {
    let enabled: Bool
    let speed: Double
    var scrollRequest = 0
    var onBoundary: ((Int) -> Void)?
    var holdEnabled = false
    var onHoldChange: ((Double?) -> Void)?
    var onTap: ((CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(scrollRequest: scrollRequest) }
    func makeUIView(context: Context) -> EdgeHoldView {
        let view = EdgeHoldView(frame: .zero)
        view.addGestureRecognizer(context.coordinator.holdRecognizer)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.require(toFail: context.coordinator.holdRecognizer)
        view.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: doubleTap)
        tap.require(toFail: context.coordinator.holdRecognizer)
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: EdgeHoldView, context: Context) {
        view.holdEnabled = holdEnabled
        context.coordinator.onHoldChange = onHoldChange
        context.coordinator.onBoundary = onBoundary
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.speed = speed
        context.coordinator.holdEnabled = holdEnabled
        context.coordinator.setEnabled(enabled, in: view)
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.attachHold(to: view)
        }
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
    }
    static func dismantleUIView(_ view: EdgeHoldView, coordinator: Coordinator) {
        coordinator.dismantled = true
        coordinator.setEnabled(false, in: view)
        coordinator.holdRecognizer.view?.removeGestureRecognizer(coordinator.holdRecognizer)
    }
    static func trace(_ message: @autoclosure () -> String) {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-YokaiReaderTrace") {
            FileHandle.standardError.write(Data("Reader edge \(message())\n".utf8))
        }
        #endif
    }
    final class EdgeHoldView: UIView {
        var holdEnabled = false
        weak var scrollView: UIScrollView?
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard holdEnabled, let scroll = scrollView, bounds.contains(point) else { return false }
            let location = convert(point, to: scroll)
            let x = location.x - scroll.bounds.minX, y = location.y - scroll.bounds.minY
            let accepts = (x >= 0 && x < 28 || x > scroll.bounds.width - 28 && x <= scroll.bounds.width)
                && y > 32 && y < scroll.bounds.height - 32
            // The overlay is a sibling of the images, so their menus never receive edge touches.
            AutoScrollDriver.trace("hit viewport=\(CGPoint(x: x, y: y)) accepts=\(accepts) bounds=\(scroll.bounds)")
            return accepts
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval?
        private weak var scrollView: UIScrollView?
        var speed = 40.0
        var scrollRequest: Int
        var reachedEnd = false
        var onHoldChange: ((Double?) -> Void)?
        var onBoundary: ((Int) -> Void)?
        var onTap: ((CGPoint) -> Void)?
        var onDoubleTap: (() -> Void)?
        var holdEnabled = false
        var dismantled = false
        private var holdStartY: CGFloat = 0
        private var holdStartSpeed = 40.0
        #if DEBUG && targetEnvironment(simulator)
        private var traceTimestamp: CFTimeInterval = 0
        #endif
        lazy var holdRecognizer: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
            gesture.minimumPressDuration = 0.35
            gesture.allowableMovement = 12
            gesture.delegate = self
            return gesture
        }()
        init(scrollRequest: Int) { self.scrollRequest = scrollRequest }
        deinit { displayLink?.invalidate() }
        func setEnabled(_ enabled: Bool, in view: UIView) {
            guard enabled, !dismantled else {
                if displayLink != nil { AutoScrollDriver.trace("displayLink stop offset=\(String(describing: scrollView?.contentOffset))") }
                displayLink?.invalidate(); displayLink = nil; lastTimestamp = nil; reachedEnd = false
                return
            }
            guard displayLink == nil else { return }
            let target = DisplayLinkTarget(self)
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
            let rate = Float((view.window?.screen ?? UIScreen.main).maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
            displayLink = link
            AutoScrollDriver.trace("displayLink start speed=\(speed) preferredFPS=\(rate)")
            link.add(to: .main, forMode: .common)
        }
        private func tick(_ link: CADisplayLink) {
            guard let scroll = scrollView, scroll.window != nil, !scroll.isDragging, !scroll.isDecelerating, !scroll.isZooming else {
                lastTimestamp = nil
                return
            }
            let previous = lastTimestamp
            lastTimestamp = link.timestamp
            guard let previous else { return }
            let elapsed = link.timestamp - previous
            // A suspended app or stalled frame must not catch up with a large jump.
            guard elapsed > 0, elapsed < 0.25 else { return }
            let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            if scroll.contentOffset.y >= end - 1 {
                if !reachedEnd { reachedEnd = true; onBoundary?(1) }
            } else {
                reachedEnd = false
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(end, scroll.contentOffset.y + speed * elapsed)), animated: false)
                #if DEBUG && targetEnvironment(simulator)
                if link.timestamp - traceTimestamp > 0.5 {
                    traceTimestamp = link.timestamp
                    AutoScrollDriver.trace("tick speed=\(speed) dt=\(elapsed) offset=\(scroll.contentOffset)")
                }
                #endif
            }
        }
        private final class DisplayLinkTarget: NSObject {
            weak var coordinator: Coordinator?
            init(_ coordinator: Coordinator) { self.coordinator = coordinator }
            @objc func tick(_ link: CADisplayLink) { coordinator?.tick(link) }
        }
        func attachHold(to view: EdgeHoldView) {
            guard !dismantled else { return }
            var ancestor = view.superview
            while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
            let scroll = ancestor as? UIScrollView
            if scrollView !== scroll || holdRecognizer.isEnabled != holdEnabled {
                AutoScrollDriver.trace("attach scroll=\(String(describing: scroll.map { type(of: $0) })) enabled=\(holdEnabled) overlay=\(view.bounds) viewport=\(String(describing: scroll?.bounds))")
            }
            scrollView = scroll; view.scrollView = scroll
            holdRecognizer.isEnabled = holdEnabled
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = scrollView else { return false }
            let begins = !scroll.isDragging && !scroll.isZooming
            AutoScrollDriver.trace("shouldBegin=\(begins) dragging=\(scroll.isDragging) zooming=\(scroll.isZooming)")
            return begins
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            let location = gesture.location(in: scroll)
            onTap?(CGPoint(x: location.x - scroll.bounds.minX, y: location.y - scroll.bounds.minY))
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            onDoubleTap?()
        }
        @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
            // Window coordinates stay fixed while the underlying scroll view moves.
            let y = gesture.location(in: gesture.view?.window).y
            AutoScrollDriver.trace("hold state=\(gesture.state.rawValue) y=\(y) speed=\(speed)")
            switch gesture.state {
            case .began:
                holdStartY = y; holdStartSpeed = speed
                onHoldChange?(ReaderScrollSpeed.adjusted(start: holdStartSpeed, translation: 0))
            case .changed:
                onHoldChange?(ReaderScrollSpeed.adjusted(start: holdStartSpeed, translation: y - holdStartY))
            case .ended, .cancelled, .failed: onHoldChange?(nil)
            default: break
            }
        }
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
        guard let crop = borderCropRect(), let trimmed = cgImage?.cropping(to: crop) else { return self }
        return UIImage(cgImage: trimmed, scale: scale, orientation: imageOrientation)
    }
    func borderCropRect() -> CGRect? {
        guard let original = cgImage else { return nil }
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
        return crop
    }
}
