import Foundation
import Security

struct KeychainPasswordStore: Sendable {
  private let service = "com.dreamyoungs.solnari.database-password"

  func save(_ password: String, for profileID: UUID) throws {
    if password.isEmpty {
      try delete(for: profileID)
      return
    }

    let account = profileID.uuidString
    let passwordData = Data(password.utf8)
    let lookup: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
    ]
    let attributes: [CFString: Any] = [
      kSecValueData: passwordData,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)

    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw SolnariDatabaseError.keychain(updateStatus)
    }

    var addition = lookup
    addition[kSecValueData] = passwordData
    addition[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(addition as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw SolnariDatabaseError.keychain(addStatus)
    }
  }

  func password(for profileID: UUID) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: profileID.uuidString,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SolnariDatabaseError.keychain(status)
    }
    return String(data: data, encoding: .utf8)
  }

  func delete(for profileID: UUID) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: profileID.uuidString,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SolnariDatabaseError.keychain(status)
    }
  }
}
