#if MIGRATE_LIVE_CONTAINER
import Foundation
import Security

/// Only present in the one-time handoff build. The distributed host has no
/// entitlement to LiveContainer's Keychain and runs independently afterwards.
enum HostKeychainMigration {
    static func perform() throws {
        guard let oldGroup = Bundle.main.object(forInfoDictionaryKey: "HubMigrationKeychainGroup") as? String,
              let ownGroup = Bundle.main.object(forInfoDictionaryKey: "HubOwnKeychainGroup") as? String else { return }
        var count = 0
        for service in ["com.wyih.yokai.extension-preferences", "com.wyih.yokai.webdav"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccessGroup as String: oldGroup,
                kSecReturnAttributes as String: true, kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw failure(status) }
            for row in rows {
                guard let name = row[kSecAttrAccount as String] as? String,
                      let data = row[kSecValueData as String] as? Data else { throw failure(errSecDecode) }
                let destination: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: name,
                    kSecAttrAccessGroup as String: ownGroup]
                let values: [String: Any] = [kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
                var write = SecItemUpdate(destination as CFDictionary, values as CFDictionary)
                if write == errSecItemNotFound { write = SecItemAdd(destination.merging(values) { _, new in new } as CFDictionary, nil) }
                guard write == errSecSuccess else { throw failure(write) }
                count += 1
            }
        }
        let report = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("host-keychain-migration.json")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["migrated": count, "completed": true]).write(to: report, options: .atomic)
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "HostMigration", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "图源登录数据迁移失败（\(status)）"])
    }
}
#endif
