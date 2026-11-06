import Foundation

enum DuplicateChapterProgress {
    static let existingKey = "reader.markDuplicateReadExisting"
    static let newKey = "reader.markDuplicateReadNew"

    static func marking(_ progress: [ChapterProgress],
                        chapters: [(url: String, title: String, number: Double)],
                        completedURLs: Set<String>, eligibleURLs: Set<String>? = nil,
                        now: Date = Date()) -> [ChapterProgress] {
        let numbers = Set(chapters.filter { completedURLs.contains($0.url) && $0.number >= 0 && $0.number.isFinite }.map(\.number))
        guard !numbers.isEmpty else { return progress }
        var result = progress
        var indices = Dictionary(result.enumerated().map { ($0.element.url, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for chapter in chapters where numbers.contains(chapter.number) && !completedURLs.contains(chapter.url)
            && (eligibleURLs == nil || eligibleURLs!.contains(chapter.url)) {
            if let index = indices[chapter.url] {
                guard !result[index].completed else { continue }
                result[index].completed = true
                result[index].modifiedAt = now
            } else {
                indices[chapter.url] = result.count
                result.append(ChapterProgress(url: chapter.url, title: chapter.title, pageCount: 1, lastPage: 0,
                                              completed: true, modifiedAt: now))
            }
        }
        return result
    }
}
