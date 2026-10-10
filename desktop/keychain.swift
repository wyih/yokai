import Foundation
import Security

// A macOS executable uses the login keychain. Catalyst's data protection
// keychain requires a provisioning profile, which local desktop builds lack.
do {
    let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: String]
    guard let input, let service = input["service"], let account = input["account"],
          ["com.wyih.yokai.extension-preferences", "com.wyih.yokai.webdav"].contains(service) else {
        throw NSError(domain: "YokaiKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "凭据请求无效。"])
    }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                              kSecAttrService as String: service, kSecAttrAccount as String: account]
    var output: [String: String] = [:]
    var status: OSStatus
    if input["operation"] == "read" {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { status = errSecSuccess; output["value"] = "" }
        else if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) { output["value"] = value }
        else if status == errSecSuccess { status = errSecDecode }
    } else if input["operation"] == "write", let value = input["value"] {
        let data = Data(value.utf8)
        status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        output["value"] = ""
    } else { throw NSError(domain: "YokaiKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "凭据操作无效。"]) }
    if status != errSecSuccess {
        output = ["error": "无法访问系统钥匙串（\(status)）。"]
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
} catch {
    let data = try! JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
    FileHandle.standardOutput.write(data)
}
