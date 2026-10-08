import UIKit

@MainActor
final class ReaderBrightness {
    private let read: () -> CGFloat
    private let write: (CGFloat) -> Void
    private var systemBrightness: CGFloat?
    private var appliedBrightness: CGFloat?

    init(read: @escaping () -> CGFloat = { UIScreen.main.brightness },
         write: @escaping (CGFloat) -> Void = { UIScreen.main.brightness = $0 }) {
        self.read = read; self.write = write
    }

    func apply(enabled: Bool, value: Double) {
        guard enabled, value != 0 else { restore(); return }
        let current = read()
        if systemBrightness == nil || appliedBrightness.map({ abs(current - $0) > 0.005 }) == true {
            systemBrightness = current
        }
        let target = max(0.01, min(1, CGFloat(value)))
        if abs(current - target) > 0.0001 { write(target) }
        appliedBrightness = target
    }

    func restore() {
        guard let original = systemBrightness, let applied = appliedBrightness else { return }
        systemBrightness = nil; appliedBrightness = nil
        // UIScreen brightness is device-wide. Restore only our own override;
        // retain brightness changes made through the system while reading.
        if abs(read() - applied) <= 0.005 { write(original) }
    }
}
