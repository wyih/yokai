import Foundation

struct ReadingSegment: Equatable {
    let page: Int
    /// nil for a complete image, 0 for its left half, 1 for its right half.
    var half: Int?
}
struct ReadingFrame: Equatable, Identifiable {
    let id: Int
    let segments: [ReadingSegment]
}
enum ReadingLayout {
    static func frames(count: Int, wide: Set<Int>, double: Bool, split: Bool, rightFirst: Bool, shift: Bool) -> [ReadingFrame] {
        var frames: [ReadingFrame] = []
        var page = 0
        while page < count {
            if split && wide.contains(page) {
                for half in rightFirst ? [1, 0] : [0, 1] {
                    frames.append(ReadingFrame(id: frames.count, segments: [ReadingSegment(page: page, half: half)]))
                }
                page += 1
            } else {
                var segments = [ReadingSegment(page: page)]
                if double && !(shift && page == 0) && !wide.contains(page) && page + 1 < count && !wide.contains(page + 1) {
                    segments.append(ReadingSegment(page: page + 1)); page += 1
                }
                frames.append(ReadingFrame(id: frames.count, segments: segments)); page += 1
            }
        }
        return frames
    }
}
