import Foundation

/// Standalone paths remain unchanged; the host uses its own namespace.
enum YokaiStorage {
    #if READING_HUB
    static let preferencesDomain = "com.wyih.readinghub.yokai"
    static let defaults = UserDefaults(suiteName: preferencesDomain)!
    static let documents = directory(.documentDirectory).appendingPathComponent("Yokai", isDirectory: true)
    static let support = directory(.applicationSupportDirectory).appendingPathComponent("Yokai", isDirectory: true)
    #else
    static var preferencesDomain: String { Bundle.main.bundleIdentifier ?? "com.wyih.yokai" }
    static let defaults = UserDefaults.standard
    static let documents = directory(.documentDirectory)
    static let support = directory(.applicationSupportDirectory)
    #endif
    private static func directory(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask)[0]
    }
}
