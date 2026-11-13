import Foundation
import CoreGraphics

enum PagePan {
    // Leave a small overlap so the reader keeps their place after each tap.
    static func offset(current: CGPoint, content: CGSize, viewport: CGSize, direction: CGVector) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let maxX = max(0, content.width - viewport.width), maxY = max(0, content.height - viewport.height)
        let start = CGPoint(x: min(maxX, max(0, current.x)), y: min(maxY, max(0, current.y)))
        let target = CGPoint(x: min(maxX, max(0, start.x + direction.dx * viewport.width * 0.9)),
                             y: min(maxY, max(0, start.y + direction.dy * viewport.height * 0.9)))
        return abs(target.x - start.x) > 0.5 || abs(target.y - start.y) > 0.5 ? target : nil
    }
}
