import Foundation

struct NativeShelfBackup: Codable {
    var version = 1
    let shelf: ShelfState
    var preferences: Data?
    var sourcePreferences: [AndroidSourcePreferences]?
    var details: [String: SourceDetails]?
}

enum NativeBackup {
    private static func allowed(_ key: String) -> Bool {
        ["reader.", "tapZones.", "chapters.display.", "library.", "downloads.", "extensions.", "navigation.", "sources.", "source.savedSearches."].contains(where: key.hasPrefix)
        || ["appearance", "accent", "readerMode", "rightToLeft", "readerBackground", "trimBorders", "autoScrollSpeed"].contains(key)
    }
    @MainActor static func export(library: ComicLibrary, extensions: ExtensionStore, appPreferences: Bool, sourcePreferences: Bool) async throws -> Data {
        var backup = NativeShelfBackup(shelf: library.snapshot())
        backup.details = Dictionary(uniqueKeysWithValues: library.books.compactMap { book in library.cachedDetails(for: book).map { (book.id, $0) } })
        if appPreferences {
            let defaults = YokaiStorage.defaults.persistentDomain(forName: YokaiStorage.preferencesDomain) ?? [:]
            backup.preferences = try PropertyListSerialization.data(fromPropertyList: defaults.filter { allowed($0.key) }, format: .binary, options: 0)
        }
        if sourcePreferences { await extensions.start(); backup.sourcePreferences = try await SourceEngine.call("exportSourcePreferences", as: [AndroidSourcePreferences].self) }
        return try JSONEncoder().encode(backup)
    }
    static func preferences(_ data: Data) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw SyncError.invalidData }
        return values.filter { allowed($0.key) }
    }
}
