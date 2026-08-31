import Foundation
import Security

protocol ConnectionProfileVault {
  func save(_ profile: ConnectionProfile) throws
  func profile(for profileID: UUID) throws -> ConnectionProfile?
  func delete(profileID: UUID) throws
}

struct KeychainConnectionProfileVault: ConnectionProfileVault, Sendable {
  private let service = "com.dreamyoungs.solnari.connection-profile"

  func save(_ profile: ConnectionProfile) throws {
    let payload = try JSONEncoder().encode(profile.persisted())
    let lookup = query(profileID: profile.id)
    let updateStatus = SecItemUpdate(
      lookup as CFDictionary,
      [
        kSecValueData: payload,
        kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw SolnariDatabaseError.keychain(updateStatus)
    }

    var addition = lookup
    addition[kSecValueData] = payload
    addition[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(addition as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw SolnariDatabaseError.keychain(addStatus)
    }
  }

  func profile(for profileID: UUID) throws -> ConnectionProfile? {
    var lookup = query(profileID: profileID)
    lookup[kSecReturnData] = true
    lookup[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SolnariDatabaseError.keychain(status)
    }
    return try JSONDecoder().decode(ConnectionProfile.self, from: data).persisted()
  }

  func delete(profileID: UUID) throws {
    let status = SecItemDelete(query(profileID: profileID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SolnariDatabaseError.keychain(status)
    }
  }

  private func query(profileID: UUID) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: profileID.uuidString,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
    ]
  }
}
