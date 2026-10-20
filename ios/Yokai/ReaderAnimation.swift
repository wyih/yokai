import SwiftUI
import ImageIO

struct ReaderPageImage {
    let image: UIImage
    let animation: ReaderImageAnimation?

    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        self.image = image
        animation = ReaderImageAnimation(data: data)
    }
}

final class ReaderImageAnimation {
    private let source: CGImageSource
    let durations: [TimeInterval]
    let loopCount: Int
    private let lock = NSLock()

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 1 else { return nil }
        let keys: (CFString, CFString, CFString, CFString)
        switch CGImageSourceGetType(source) as String? {
        case "org.webmproject.webp":
            keys = (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPLoopCount)
        case "com.compuserve.gif":
            keys = (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFLoopCount)
        case "public.png":
            keys = (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGLoopCount)
        default: return nil
        }
        self.source = source
        durations = (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let animation = properties?[keys.0] as? [CFString: Any]
            let delay = (animation?[keys.1] as? Double) ?? (animation?[keys.2] as? Double) ?? 0.1
            return delay.isFinite && delay > 0.01 ? delay : 0.1
        }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let animation = properties?[keys.0] as? [CFString: Any]
        let loops = animation?[keys.3] as? Int
        // GIF counts repetitions after the first pass; WebP/APNG count total passes.
        if let loops { loopCount = keys.0 == kCGImagePropertyGIFDictionary && loops > 0 ? loops + 1 : loops }
        else { loopCount = 1 }
    }

    func frame(at index: Int) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let frame = CGImageSourceCreateImageAtIndex(source, index,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: frame)
        return image.preparingForDisplay() ?? image
    }
}

struct ReaderImageTransform {
    var half: Int?
    var stackSpread = false
    var rightFirst = false
    var spreadGap: CGFloat = 0
    var crop: CGRect?

    func apply(to image: UIImage) -> UIImage {
        var result = image
        if let half { result = result.spreadHalf(half) }
        if stackSpread { result = result.stackingSpread(rightFirst: rightFirst, gap: spreadGap) }
        if let crop, let cgImage = result.cgImage?.cropping(to: crop) {
            result = UIImage(cgImage: cgImage, scale: result.scale, orientation: result.imageOrientation)
        }
        return result
    }
}

final class ReaderAnimatedImageView: UIImageView {
    private var animation: ReaderImageAnimation?
    private var poster: UIImage?
    private var frameTransform = ReaderImageTransform()
    private var playback: Task<Void, Never>?
    private var enabled = false

    func configure(image: UIImage, animation: ReaderImageAnimation?, transform: ReaderImageTransform, playing: Bool) {
        if poster !== image || self.animation !== animation {
            playback?.cancel(); playback = nil
            poster = image; self.animation = animation; frameTransform = transform
            self.image = image
        }
        enabled = playing
        updatePlayback()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePlayback()
    }

    private func updatePlayback() {
        guard enabled, window != nil, let animation else {
            playback?.cancel(); playback = nil
            return
        }
        guard playback == nil else { return }
        image = poster
        let transform = frameTransform
        playback = Task { [weak self] in
            var index = 0, completedLoops = 0
            while !Task.isCancelled {
                let started = CACurrentMediaTime()
                let next = (index + 1) % animation.durations.count
                if next == 0 {
                    completedLoops += 1
                    if animation.loopCount > 0 && completedLoops >= animation.loopCount { return }
                }
                // Decode only the next frame, away from scrolling and gesture handling.
                let frame = await Task.detached(priority: .userInitiated) {
                    autoreleasepool { animation.frame(at: next).map { transform.apply(to: $0) } }
                }.value
                let remaining = animation.durations[index] - (CACurrentMediaTime() - started)
                if remaining > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled, let frame else { return }
                self?.image = frame
                index = next
            }
        }
    }

    deinit { playback?.cancel() }
}

struct AnimatedReaderImage: UIViewRepresentable {
    let image: UIImage
    let animation: ReaderImageAnimation
    let transform: ReaderImageTransform
    let playing: Bool

    func makeUIView(context: Context) -> ReaderAnimatedImageView {
        let view = ReaderAnimatedImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: ReaderAnimatedImageView, context: Context) {
        view.configure(image: image, animation: animation, transform: transform, playing: playing)
    }
}
