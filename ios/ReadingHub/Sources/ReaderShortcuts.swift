import AppIntents
import Foundation

extension ReaderModule: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "阅读器"
    static var caseDisplayRepresentations: [ReaderModule: DisplayRepresentation] = [
        .yokai: "Yōkai 漫画", .qiye: "栖页"
    ]
}

struct OpenReaderIntent: AppIntent {
    static var title: LocalizedStringResource = "打开阅读器"
    static var description = IntentDescription("直接打开书房中的漫画或栖页。")
    static var openAppWhenRun = true
    @Parameter(title: "阅读器") var reader: ReaderModule
    init() {}
    init(reader: ReaderModule) { self.reader = reader }
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(reader.rawValue, forKey: "hub.pendingModule")
        await MainActor.run { NotificationCenter.default.post(name: .openHubModule, object: nil) }
        return .result()
    }
}

struct ReaderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenReaderIntent(reader: .yokai), phrases: ["用\(.applicationName)打开漫画"], shortTitle: "打开漫画", systemImageName: "books.vertical")
        AppShortcut(intent: OpenReaderIntent(reader: .qiye), phrases: ["用\(.applicationName)打开栖页"], shortTitle: "打开栖页", systemImageName: "book")
    }
}
