import Foundation
import CoreFoundation

enum AndroidPreferenceValue: Codable {
    case string(String), integer(Int64), decimal(Double), boolean(Bool), strings([String])
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let v = try? value.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .decimal(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else { self = .strings(try value.decode([String].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .string(let v): try container.encode(v); case .integer(let v): try container.encode(v); case .decimal(let v): try container.encode(v); case .boolean(let v): try container.encode(v); case .strings(let v): try container.encode(v) }
    }
    var object: Any { switch self { case .string(let v): v; case .integer(let v): v; case .decimal(let v): v; case .boolean(let v): v; case .strings(let v): v } }
}
struct AndroidPreference: Codable { var key: String; var type: String; var value: AndroidPreferenceValue }
struct AndroidSourcePreferences: Codable { var name: String; var preferences: [AndroidPreference] }

struct AndroidShelfBackup: Decodable {
    struct Category: Decodable { let name: String; let order: Int }
    struct Manga: Decodable {
        struct Chapter: Decodable {
            let url, name, memo: String
            let read, bookmark: Bool
            let lastPage, pagesLeft: Int
            let readAt: Int64
            let number: Double
            let uploaded: Int64
            let sourceOrder: Int
        }
        let source, url, title, thumbnail, memo: String
        let addedAt: Int64
        let chapters: [Chapter]
        let categories: [String]
        let artist, author, description: String
        let genre: [String]
        let status: Int
        let favorite: Bool
        let viewerFlags: Int
        let androidData: String
        var bookID: String { ComicLibrary.hash(source + "\n" + url) }
        var details: SourceDetails {
            SourceDetails(manga: SourceManga(url: url, title: title, thumbnail: thumbnail,
                author: author, artist: artist, description: description, genre: genre.joined(separator: ", "), status: status, memo: validAndroidMemo(memo)),
                chapters: chapters.sorted { $0.sourceOrder < $1.sourceOrder }.map {
                    SourceChapter(url: $0.url, name: $0.name, number: $0.number, uploaded: $0.uploaded, memo: validAndroidMemo($0.memo))
                })
        }
    }
    let manga: [Manga]
    let categoryList: [Category]
    let extraFields: String
    let appPreferences: [AndroidPreference]
    let sourcePreferences: [AndroidSourcePreferences]
    func shelf() throws -> ShelfState {
        let books = try manga.map { manga -> ComicBook in
            var book = ComicBook(id: manga.bookID, title: manga.title, format: .images, pageCount: 1,
                importedAt: manga.addedAt > 0 ? Date(timeIntervalSince1970: Double(manga.addedAt) / 1000) : Date())
            book.origin = ComicOrigin(sourceID: manga.source, mangaURL: manga.url, thumbnail: manga.thumbnail.isEmpty ? nil : manga.thumbnail, mangaMemo: validAndroidMemo(manga.memo))
            book.inLibrary = manga.favorite
            book.categories = manga.categories
            book.androidBackupData = manga.androidData
            book.readerSettings = MangaReaderSettings(mode: AndroidBackupService.mode(manga.viewerFlags & 7),
                orientation: AndroidBackupService.orientation((manga.viewerFlags >> 3) & 7))
            book.mangaInfo = MangaMetadata(author: manga.author, artist: manga.artist, genre: manga.genre.joined(separator: ", "), status: manga.status,
                chapterCount: manga.chapters.count, latestUpload: manga.chapters.map(\.uploaded).max() ?? 0, fetchedAt: Date())
            book.chapters = try manga.chapters.map { chapter in
                let (base, overflow1) = chapter.lastPage.addingReportingOverflow(1)
                let (count, overflow2) = base.addingReportingOverflow(chapter.pagesLeft)
                guard !overflow1, !overflow2, count > 0 else { throw SyncError.invalidData }
                return ChapterProgress(url: chapter.url, title: chapter.name, pageCount: count, lastPage: chapter.lastPage, completed: chapter.read,
                    lastRead: chapter.readAt > 0 ? Date(timeIntervalSince1970: Double(chapter.readAt) / 1000) : nil,
                    bookmarked: chapter.bookmark, bookmarkModifiedAt: chapter.bookmark ? Date() : nil)
            }
            if let current = manga.chapters.filter({ $0.readAt > 0 }).max(by: { $0.readAt < $1.readAt }),
               let progress = book.chapters?.first(where: { $0.url == current.url }) {
                book.origin?.chapterURL = current.url; book.origin?.chapterTitle = current.name; book.origin?.chapterMemo = validAndroidMemo(current.memo)
                book.pageCount = progress.pageCount; book.lastPage = progress.lastPage; book.lastRead = progress.lastRead
            }
            if book.lastRead != nil { book.historyModifiedAt = Date() }
            for index in (book.chapters ?? []).indices where book.chapters?[index].lastRead != nil { book.chapters?[index].historyModifiedAt = Date() }
            return book
        }
        return ShelfState(books: books, categories: categoryList.map { ShelfCategory(id: "android-" + ComicLibrary.hash($0.name), name: $0.name, order: $0.order) })
    }
}

private func validAndroidMemo(_ raw: String) -> String {
    (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) is [String: Any] ? raw : "{}"
}

enum AndroidBackupService {
    @MainActor static func restore(_ url: URL, library: ComicLibrary, extensions: ExtensionStore, appPreferences: Bool = true, sourcePreferences: Bool = true) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["json", "tmb", "tachibk", "gz"].contains(url.pathExtension.lowercased()),
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw SourceError.message("请选择 .tmb、.tachibk、.proto.gz 或 .json 备份文件。")
        }
        let state: ShelfState
        var android: AndroidShelfBackup?
        var native: NativeShelfBackup?
        let tachimanga = url.pathExtension.lowercased() == "tmb"
        var preferences: [String: Any] = [:]
        if tachimanga {
            let backup = try await Task.detached(priority: .userInitiated) { try TachimangaBackup.read(url) }.value
            native = backup; state = backup.shelf
            if appPreferences, let data = backup.preferences { preferences = try NativeBackup.preferences(data) }
        } else if url.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: url)
            if let backup = try? JSONDecoder().decode(NativeShelfBackup.self, from: data) {
                guard backup.version == 1 else { throw SyncError.invalidData }
                native = backup; state = backup.shelf
                guard (backup.details ?? [:]).keys.allSatisfy(Set(state.books.map(\.id)).contains) else { throw SyncError.invalidData }
                if appPreferences, let data = backup.preferences { preferences = try NativeBackup.preferences(data) }
            } else { state = try JSONDecoder().decode(ShelfState.self, from: data) }
        }
        else {
            await extensions.start()
            let imported = try await SourceEngine.call("readAndroidBackup", ["path": url.path], as: AndroidShelfBackup.self)
            android = imported; state = try imported.shelf()
        }
        try ShelfMerge.validate(state)
        let current = library.snapshot()
        var restored: ShelfState
        if android != nil || tachimanga { restored = AndroidBackupMerge.restore(current: current, backup: state) }
        else {
            let conflicts = ShelfMerge.merge(local: current, remote: state, baseline: [:]).conflicts
            let choices = Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, ProgressChoice(conflict: $0, keepLocal: true)) })
            restored = ShelfMerge.merge(local: current, remote: state, baseline: [:], choices: choices).state
        }
        if tachimanga {
            let existingShelf = Set(current.books.filter { $0.inLibrary != false }.map(\.id))
            for index in restored.books.indices where existingShelf.contains(restored.books[index].id) { restored.books[index].inLibrary = true }
        }
        try ShelfMerge.validate(restored)
        // Write chapter caches before publishing the merged shelf, so an I/O
        // failure cannot leave newly imported titles without their chapter list.
        if let android { for manga in android.manga { try library.cacheImportedDetails(manga.details, bookID: manga.bookID) } }
        if let native { for (id, details) in native.details ?? [:] { try library.cacheImportedDetails(details, bookID: id) } }
        library.acceptSync(restored, captured: current)
        if let android {
            let _: Bool = try await SourceEngine.call("storeAndroidBackupExtras", ["extraFields": android.extraFields], as: Bool.self)
            if appPreferences { restoreAppPreferences(android.appPreferences, categories: android.categoryList) }
            if sourcePreferences {
                let records = try JSONSerialization.jsonObject(with: JSONEncoder().encode(android.sourcePreferences))
                let _: Bool = try await SourceEngine.call("restoreSourcePreferences", ["preferences": records], as: Bool.self)
                try await extensions.reloadPreferences()
            }
        }
        if let native {
            for (key, value) in preferences { UserDefaults.standard.set(value, forKey: key) }
            if sourcePreferences, let records = native.sourcePreferences {
                await extensions.start()
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
                let _: Bool = try await SourceEngine.call("restoreSourcePreferences", ["preferences": encoded], as: Bool.self)
                try await extensions.reloadPreferences()
            }
        }
        try await library.flushPendingSaves()
    }
    private static let preferenceKeys = [
        "pref_keep_screen_on_key": "reader.keepAwake", "fullscreen": "reader.fullscreen", "pref_show_page_number_key": "reader.showPageNumber",
        "crop_borders": "trimBorders", "pref_enable_transitions_key": "reader.animate", "pref_grayscale": "reader.grayscale",
        "pref_inverted_colors": "reader.inverted", "skip_read": "reader.skipRead", "skip_filtered": "reader.skipFiltered",
        "pref_download_only_over_wifi_key": "downloads.wifiOnly", "download_new": "downloads.newChapters",
        "pref_library_update_interval_key": "library.updateHours", "webtoon_side_padding": "reader.sidePadding",
        "remove_after_read_slots": "downloads.removeAfterRead", "pref_remove_after_marked_as_read_key": "downloads.removeAfterMarked",
        "pref_remove_bookmarked": "downloads.removeBookmarks", "pref_custom_brightness_key": "reader.customBrightness",
        "auto_download_while_reading": "downloads.aheadChapters", "skip_dupe": "reader.skipDuplicate",
        "pref_color_filter_key": "reader.colorFilter", "color_filter_value": "reader.colorFilterValue", "color_filter_mode": "reader.colorFilterMode",
        "reader_long_tap": "reader.longTap", "pref_enable_double_tap_zoom_webtoon": "reader.webtoonDoubleTap", "webtoon_enable_zoom_out": "reader.webtoonZoomOut",
        "automatic_splits_page": "reader.splitPortrait", "invert_double_pages": "reader.invertDoublePages", "webtoon_invert_double_pages": "reader.webtoonInvertDoublePages"
    ]
    private static let categoryPreferenceKeys = ["library_update_categories": "library.updateCategories", "library_update_categories_exclude": "library.updateExcludedCategories",
        "download_new_categories": "downloads.newCategories", "download_new_categories_exclude": "downloads.newExcludedCategories", "remove_exclude_categories": "downloads.removeExcludedCategories"]
    static func restoreAppPreferences(_ preferences: [AndroidPreference], categories: [AndroidShelfBackup.Category] = []) {
        let defaults = UserDefaults.standard
        for preference in preferences {
            if let key = preferenceKeys[preference.key] { defaults.set(preference.value.object, forKey: key) }
            if let key = categoryPreferenceKeys[preference.key], case .strings(let orders) = preference.value {
                defaults.set(categories.filter { orders.contains(String($0.order)) }.map(\.name), forKey: key)
            }
            if preference.key == "library_update_restriction", case .strings(let flags) = preference.value {
                defaults.set(flags.contains("wifi"), forKey: "library.updateWifi"); defaults.set(flags.contains("ac"), forKey: "library.updateCharging")
            }
            if preference.key == "pref_default_reading_mode_key", case .integer(let flag) = preference.value,
               let mode = mode(Int(flag) & 7) { defaults.set(mode, forKey: "readerMode") }
            if preference.key == "pref_default_orientation_type_key", case .integer(let flag) = preference.value,
               let orientation = orientation((Int(flag) >> 3) & 7) { defaults.set(orientation, forKey: "reader.orientation") }
            if preference.key == "pref_image_scale_type_key", case .integer(let flag) = preference.value {
                defaults.set([1: "fit", 2: "stretch", 3: "width", 4: "height", 5: "original", 6: "smart"][Int(flag)] ?? "fit", forKey: "reader.scale")
            }
            if preference.key == "pref_zoom_start_key", case .integer(let flag) = preference.value {
                defaults.set([1: "auto", 2: "left", 3: "right", 4: "center"][Int(flag)] ?? "auto", forKey: "reader.zoomStart")
            }
            if preference.key == "custom_brightness_value", case .integer(let value) = preference.value { defaults.set(max(-0.75, min(1, Double(value) / 100)), forKey: "reader.brightness") }
            if preference.key == "page_layout", case .integer(let flag) = preference.value {
                defaults.set([0: "single", 1: "double", 2: "automatic", 3: "split"][Int(flag)] ?? "automatic", forKey: "reader.layout")
                defaults.set(false, forKey: "reader.doublePage")
            }
            if preference.key == "webtoon_page_layout", case .integer(let flag) = preference.value { defaults.set(flag == 1, forKey: "reader.webtoonSplit") }
            let presets = ["default", "l", "kindlish", "edge", "sides", "disabled"]
            for (android, ios) in [("reader_navigation_mode_pager", "tapZones.pager.preset"), ("reader_navigation_mode_webtoon", "tapZones.webtoon.preset")] {
                if preference.key == android, case .integer(let index) = preference.value, presets.indices.contains(Int(index)) { defaults.set(presets[Int(index)], forKey: ios) }
            }
            for (android, ios) in [("reader_tapping_inverted", "tapZones.pager.invert"), ("reader_tapping_inverted_webtoon", "tapZones.webtoon.invert")] {
                if preference.key == android, case .string(let flag) = preference.value {
                    defaults.set(["NONE": "none", "HORIZONTAL": "horizontal", "VERTICAL": "vertical", "BOTH": "both"][flag] ?? "none", forKey: ios)
                }
            }
        }
    }
    private static func appPreferences(categoryNames: [String]) -> [[String: Any]] {
        let defaults = UserDefaults.standard
        var values: [[String: Any]] = preferenceKeys.compactMap { android, ios in
            guard let value = defaults.object(forKey: ios) else { return nil }
            return ["key": android, "type": value is NSNumber && CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() ? "boolean" : "int", "value": value]
        }
        var mode = defaults.string(forKey: "readerMode") ?? "webtoon"
        if mode == "horizontal" { mode = defaults.bool(forKey: "rightToLeft") ? "rtl" : "ltr" }
        let flags = viewerFlags(MangaReaderSettings(mode: mode, orientation: defaults.string(forKey: "reader.orientation"))) ?? 0
        values.append(["key": "pref_default_reading_mode_key", "type": "int", "value": flags & 7])
        values.append(["key": "pref_default_orientation_type_key", "type": "int", "value": flags & 56])
        values.append(["key": "pref_image_scale_type_key", "type": "int", "value": ["fit": 1, "stretch": 2, "width": 3, "height": 4, "original": 5, "smart": 6][defaults.string(forKey: "reader.scale") ?? "fit"] ?? 1])
        values.append(["key": "pref_zoom_start_key", "type": "int", "value": ["auto": 1, "left": 2, "right": 3, "center": 4][defaults.string(forKey: "reader.zoomStart") ?? "auto"] ?? 1])
        values.append(["key": "custom_brightness_value", "type": "int", "value": Int(defaults.double(forKey: "reader.brightness") * 100)])
        values.append(["key": "page_layout", "type": "int", "value": ["single": 0, "double": 1, "automatic": 2, "split": 3][defaults.string(forKey: "reader.layout") ?? "automatic"] ?? 2])
        values.append(["key": "webtoon_page_layout", "type": "int", "value": defaults.bool(forKey: "reader.webtoonSplit") ? 1 : 0])
        let presets = ["default", "l", "kindlish", "edge", "sides", "disabled"]
        for (android, ios) in [("reader_navigation_mode_pager", "tapZones.pager.preset"), ("reader_navigation_mode_webtoon", "tapZones.webtoon.preset")] {
            if let index = presets.firstIndex(of: defaults.string(forKey: ios) ?? "default") { values.append(["key": android, "type": "int", "value": index]) }
        }
        for (android, ios) in [("reader_tapping_inverted", "tapZones.pager.invert"), ("reader_tapping_inverted_webtoon", "tapZones.webtoon.invert")] {
            values.append(["key": android, "type": "string", "value": (defaults.string(forKey: ios) ?? "none").uppercased()])
        }
        for (android, ios) in categoryPreferenceKeys {
            if let selected = defaults.stringArray(forKey: ios) {
                values.append(["key": android, "type": "set", "value": categoryNames.enumerated().filter { selected.contains($0.element) }.map { String($0.offset) }])
            }
        }
        var restrictions: [String] = []
        if defaults.bool(forKey: "library.updateWifi") { restrictions.append("wifi") }; if defaults.bool(forKey: "library.updateCharging") { restrictions.append("ac") }
        values.append(["key": "library_update_restriction", "type": "set", "value": restrictions])
        return values
    }
    static func mode(_ flag: Int) -> String? {
        switch flag { case 1: "ltr"; case 2: "rtl"; case 3: "verticalPager"; case 4: "webtoon"; case 5: "vertical"; default: nil }
    }
    static func orientation(_ flag: Int) -> String? {
        switch flag { case 1: "free"; case 2, 4: "portrait"; case 3, 5: "landscape"; default: nil }
    }
    static func viewerFlags(_ settings: MangaReaderSettings?) -> Int? {
        guard let settings else { return nil }
        let mode: Int
        switch settings.mode { case "ltr": mode = 1; case "rtl": mode = 2; case "verticalPager": mode = 3; case "webtoon": mode = 4; case "vertical": mode = 5; default: mode = 0 }
        let orientation: Int
        switch settings.orientation { case "free": orientation = 1; case "portrait": orientation = 2; case "landscape": orientation = 3; default: orientation = 0 }
        return mode | (orientation << 3)
    }
    @MainActor static func export(library: ComicLibrary, extensions: ExtensionStore, appPreferences: Bool, sourcePreferences: Bool) async throws -> URL {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("yokai_\(formatter.string(from: Date())).tachibk")
        var manga: [[String: Any]] = []
        for book in library.books where book.origin != nil && (book.inLibrary != false || book.lastRead != nil) {
            guard let origin = book.origin else { continue }
            let details = library.cachedDetails(for: book)
            var chapters = details?.chapters ?? []
            let known = Set(chapters.map(\.url))
            chapters += (book.chapters ?? []).filter { !known.contains($0.url) }.map { SourceChapter(url: $0.url, name: $0.title, number: -1, uploaded: 0) }
            var item: [String: Any] = ["source": origin.sourceID, "url": origin.mangaURL, "title": book.title,
                "favorite": book.inLibrary != false, "addedAt": Int64(book.importedAt.timeIntervalSince1970 * 1000), "categories": book.categories ?? [],
                "androidData": book.androidBackupData ?? "", "chapters": chapters.enumerated().map { index, chapter -> [String: Any] in
                    let state = book.chapters?.first { $0.url == chapter.url }
                    return ["url": chapter.url, "name": chapter.name, "number": chapter.number, "uploaded": chapter.uploaded, "sourceOrder": index,
                        "memo": chapter.memo ?? "{}", "read": state?.completed ?? false, "bookmark": state?.bookmarked ?? false,
                        "lastPage": state?.lastPage ?? 0, "pagesLeft": max(0, (state?.pageCount ?? 1) - (state?.lastPage ?? 0) - 1),
                        "readAt": Int64((state?.lastRead?.timeIntervalSince1970 ?? 0) * 1000)]
                }]
            if let thumbnail = origin.thumbnail { item["thumbnail"] = thumbnail }
            if let memo = origin.mangaMemo { item["memo"] = memo }
            if let author = details?.manga.author ?? book.mangaInfo?.author { item["author"] = author }
            if let artist = details?.manga.artist ?? book.mangaInfo?.artist { item["artist"] = artist }
            if let description = details?.manga.description { item["description"] = description }
            if let genre = details?.manga.genre ?? book.mangaInfo?.genre { item["genre"] = genre.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            if let status = details?.manga.status ?? book.mangaInfo?.status { item["status"] = status }
            if let flags = viewerFlags(book.readerSettings) { item["viewerFlags"] = flags }
            manga.append(item)
        }
        let extras = try await SourceEngine.call("androidBackupExtras", as: String.self)
        let sourceRecords = try await SourceEngine.call("exportSourcePreferences", as: [AndroidSourcePreferences].self)
        let sourceObjects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sourceRecords))
        let _: Bool = try await SourceEngine.call("writeAndroidBackup", ["path": file.path, "manga": manga, "extraFields": extras,
            "appPreferences": appPreferences ? self.appPreferences(categoryNames: library.categoryNames) : [], "sourcePreferences": sourceObjects,
            "categoryNames": library.categoryNames, "includeAppPreferences": appPreferences, "includeSourcePreferences": sourcePreferences,
            "sources": extensions.sources.filter { $0.sourceID != nil }.map { ["id": $0.id, "name": $0.name ?? $0.package] }], as: Bool.self)
        // Read before presenting the exported file, catching malformed output immediately.
        let _: AndroidShelfBackup = try await SourceEngine.call("readAndroidBackup", ["path": file.path], as: AndroidShelfBackup.self)
        return file
    }
}
