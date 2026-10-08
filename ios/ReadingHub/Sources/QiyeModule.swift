import UIKit

/// Compiled in the QiyeModule framework alongside the complete existing app.
@MainActor
public final class QiyeReaderModule {
    private let reader = ReaderViewController()
    public init() {}
    public var viewController: UIViewController { reader }
    public var isReading: Bool { reader.isReading }
    public var onReadingChanged: ((Bool) -> Void)? {
        get { reader.onReadingChanged }
        set { reader.onReadingChanged = newValue }
    }
    public func receive(_ url: URL) { reader.receive(url) }
    public func active(_ active: Bool) {
        guard reader.isViewLoaded else { return }
        reader.setHostActive(active)
    }
    public func background() { if reader.isViewLoaded { reader.paused() } }
    public func foreground() { if reader.isViewLoaded { reader.resumed() } }
}
