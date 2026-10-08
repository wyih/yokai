import Foundation

/// Android backup restoration keeps completed chapters and existing bookmarks.
/// WebDAV uses a separate merge because deliberate rewinds/unbookmarking must sync.
enum AndroidBackupMerge {
    static func restore(current: ShelfState, backup: ShelfState) -> ShelfState {
        let local = Dictionary(uniqueKeysWithValues: current.books.map { ($0.id, $0) })
        let conflicts = ShelfMerge.merge(local: current, remote: backup, baseline: [:]).conflicts
        let choices = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, ProgressChoice(conflict: $0, keepLocal: false)) })
        var result = ShelfMerge.merge(local: current, remote: backup, baseline: [:], choices: choices).state
        let imported = Dictionary(uniqueKeysWithValues: backup.books.map { ($0.id, $0) })
        for index in result.books.indices {
            guard let incoming = imported[result.books[index].id], let existing = local[incoming.id] else { continue }
            var restored = result.books[index]
            var chapters = Dictionary(uniqueKeysWithValues: (existing.chapters ?? []).map { ($0.url, $0) })
            for chapter in incoming.chapters ?? [] {
                var merged = chapter
                if let old = chapters[chapter.url] {
                    merged.title = old.title
                    if (old.completed && !chapter.completed) || (chapter.lastPage == 0 && old.lastPage != 0) {
                        merged.lastPage = old.lastPage
                        merged.pageCount = max(chapter.pageCount, old.pageCount)
                    }
                    merged.completed = chapter.completed || old.completed
                    merged.bookmarked = chapter.bookmarked == true || old.bookmarked == true
                    merged.lastRead = latest(chapter.lastRead, old.lastRead)
                    merged.historyModifiedAt = merged.lastRead.map { _ in Date() } ?? old.historyModifiedAt
                    merged.bookmarkModifiedAt = merged.bookmarked == true ? Date() : nil
                }
                chapters[chapter.url] = merged
            }
            restored.chapters = chapters.isEmpty ? nil : chapters.values.sorted { $0.url < $1.url }
            restored.lastRead = latest(existing.lastRead, incoming.lastRead)
            restored.historyModifiedAt = restored.lastRead.map { _ in Date() } ?? existing.historyModifiedAt
            // History selects the continue-reading chapter; its restored progress
            // can come from either device under the rules above.
            let position = (incoming.lastRead ?? .distantPast) >= (existing.lastRead ?? .distantPast) ? incoming : existing
            restored.origin?.chapterURL = position.origin?.chapterURL
            restored.origin?.chapterTitle = position.origin?.chapterTitle
            restored.origin?.chapterMemo = position.origin?.chapterMemo
            if let url = position.origin?.chapterURL, let chapter = chapters[url] {
                restored.pageCount = chapter.pageCount; restored.lastPage = chapter.lastPage
            } else {
                restored.pageCount = position.pageCount; restored.lastPage = position.lastPage
            }
            if incoming.categories?.isEmpty != false { restored.categories = existing.categories }
            restored.progressRevision = UUID().uuidString
            result.books[index] = restored
        }
        // Android identifies existing categories by name, not backup database ID.
        var categories = current.categories ?? []
        for category in (backup.categories ?? []).filter({ !$0.deleted }) {
            if !categories.contains(where: { !$0.deleted && $0.name == category.name }) {
                categories.removeAll { $0.id == category.id }
                categories.append(category)
            }
        }
        result.categories = categories.isEmpty ? nil : categories
        return result
    }

    private static func latest(_ a: Date?, _ b: Date?) -> Date? {
        if let a, let b { return max(a, b) }
        return a ?? b
    }
}
