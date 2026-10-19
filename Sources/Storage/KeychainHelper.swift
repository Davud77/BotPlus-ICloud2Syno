import CryptoKit
import Foundation
import Security

/// Класс для безопасной работы со связкой ключей macOS (Keychain Services)
public final class KeychainHelper: @unchecked Sendable {
  public static let shared = KeychainHelper()

  private let serviceName = "com.synologyphotosync.credentials"

  private init() {}

  // MARK: - Сохранение данных

  public func save(key: String, value: String) throws {
    guard let data = value.data(using: .utf8) else { return }

    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: key,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(identity.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw KeychainError.unhandledError(status: status)
    }
  }

  // MARK: - Чтение данных

  public func get(key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var dataTypeRef: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

    guard status == errSecSuccess, let data = dataTypeRef as? Data else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  // MARK: - Удаление данных

  public func delete(key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: key,
    ]

    SecItemDelete(query as CFDictionary)
  }

  private var passwordKey: String {
    let config = SyncConfig.shared
    let server =
      SynologyAPIClient.shared.buildURL(baseURL: config.serverURL, endpoint: "")?.absoluteString
      ?? config.serverURL
    let identity = server + "\n" + config.username
    return "password_"
      + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Удобные методы для пароля и SID

  public func savePassword(_ password: String) throws {
    try save(key: passwordKey, value: password)
  }

  public func getPassword() -> String? {
    return get(key: passwordKey)
  }

  public func deletePassword() {
    delete(key: passwordKey)
  }

  public func saveSessionId(_ sid: String) throws {
    try save(key: "synology_session_id", value: sid)
  }

  public func getSessionId() -> String? {
    return get(key: "synology_session_id")
  }

  public func deleteSessionId() {
    delete(key: "synology_session_id")
  }

  public func clearAll() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

public enum KeychainError: LocalizedError {
  case unhandledError(status: OSStatus)

  public var errorDescription: String? {
    switch self {
    case .unhandledError(let status):
      return "Ошибка Keychain Services (статус \(status))"
    }
  }
}
