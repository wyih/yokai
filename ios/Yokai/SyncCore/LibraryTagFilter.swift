import Foundation

enum MangaGenres {
    static func tags(_ genre: String) -> [String] {
        var seen = Set<String>()
        return genre.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct LibraryTagFilter: Codable, Equatable {
    var states: [String: String] = [:]
    var matchAll = true
    var isActive: Bool { states.values.contains { $0 == "yes" || $0 == "no" } }

    func accepts(_ genre: String?) -> Bool {
        let tags = Set(MangaGenres.tags(genre ?? "").map { $0.lowercased() })
        let included = Set(states.filter { $0.value == "yes" }.keys.map { $0.lowercased() })
        let excluded = Set(states.filter { $0.value == "no" }.keys.map { $0.lowercased() })
        return tags.isDisjoint(with: excluded) && (included.isEmpty ||
            (matchAll ? included.isSubset(of: tags) : !tags.isDisjoint(with: included)))
    }
}
