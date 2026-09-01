import CryptoKit
import Foundation

struct LocalEncryptedPasswordStore: Sendable {
  private let directoryURL: URL
  private let keyFileName = "credential-vault.key"
  private let storeFileName = "passwords.json.aesgcm"

  init(directoryURL: URL? = nil) {
    if let directoryURL {
      self.directoryURL = directoryURL
    } else {
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first!
      self.directoryURL =
        applicationSupport
        .appendingPathComponent("Solnari", isDirectory: true)
        .appendingPathComponent("Credentials", isDirectory: true)
    }
  }

  func save(_ password: String, for profileID: UUID) throws {
    if password.isEmpty {
      try delete(for: profileID)
      return
    }
    var passwords = try loadPasswords()
    passwords[profileID.uuidString] = password
    try persist(passwords)
  }

  func password(for profileID: UUID) throws -> String? {
    try loadPasswords()[profileID.uuidString]
  }

  func delete(for profileID: UUID) throws {
    var passwords = try loadPasswords()
    guard passwords.removeValue(forKey: profileID.uuidString) != nil else { return }
    try persist(passwords)
  }

  private var keyURL: URL {
    directoryURL.appendingPathComponent(keyFileName, isDirectory: false)
  }

  private var storeURL: URL {
    directoryURL.appendingPathComponent(storeFileName, isDirectory: false)
  }

  private func loadPasswords() throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: storeURL.path) else { return [:] }
    let encrypted = try Data(contentsOf: storeURL)
    let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
    let plaintext = try AES.GCM.open(sealedBox, using: try encryptionKey())
    return try JSONDecoder().decode([String: String].self, from: plaintext)
  }

  private func persist(_ passwords: [String: String]) throws {
    try prepareDirectory()
    let plaintext = try JSONEncoder().encode(passwords)
    let sealedBox = try AES.GCM.seal(plaintext, using: try encryptionKey())
    guard let combined = sealedBox.combined else {
      throw LocalCredentialStoreError.invalidEncryptedPayload
    }
    try combined.write(to: storeURL, options: .atomic)
    try protectFile(at: storeURL)
  }

  private func encryptionKey() throws -> SymmetricKey {
    try prepareDirectory()
    if FileManager.default.fileExists(atPath: keyURL.path) {
      let keyData = try Data(contentsOf: keyURL)
      guard keyData.count == 32 else { throw LocalCredentialStoreError.invalidKey }
      return SymmetricKey(data: keyData)
    }

    let key = SymmetricKey(size: .bits256)
    let keyData = key.withUnsafeBytes { Data($0) }
    try keyData.write(to: keyURL, options: .withoutOverwriting)
    try protectFile(at: keyURL)
    return key
  }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
  }

  private func protectFile(at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

enum LocalCredentialStoreError: LocalizedError {
  case invalidKey
  case invalidEncryptedPayload

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      String(localized: "The local credential encryption key is invalid.")
    case .invalidEncryptedPayload:
      String(localized: "The local encrypted credential store is invalid.")
    }
  }
}
