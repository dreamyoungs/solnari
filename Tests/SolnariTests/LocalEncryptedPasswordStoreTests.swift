import Foundation
import Testing

@testable import Solnari

struct LocalEncryptedPasswordStoreTests {
  @Test("데이터베이스 비밀번호는 로컬 AES-GCM vault에 암호화해 저장한다")
  func passwordRoundTripIsEncryptedAtRest() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalEncryptedPasswordStore(directoryURL: directory)
    let profileID = UUID()
    let password = "solnari-local-encryption-validation-\(UUID().uuidString)"

    try store.save(password, for: profileID)
    #expect(try store.password(for: profileID) == password)

    let encryptedURL = directory.appendingPathComponent("passwords.json.aesgcm")
    let encryptedData = try Data(contentsOf: encryptedURL)
    #expect(!String(decoding: encryptedData, as: UTF8.self).contains(password))
    let attributes = try FileManager.default.attributesOfItem(atPath: encryptedURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try store.delete(for: profileID)
    #expect(try store.password(for: profileID) == nil)
  }

  @Test("암호화 키는 password payload와 분리하고 사용자 전용 권한으로 저장한다")
  func encryptionKeyUsesRestrictedPermissions() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariTests.\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalEncryptedPasswordStore(directoryURL: directory)

    try store.save("secret", for: UUID())

    let keyURL = directory.appendingPathComponent("credential-vault.key")
    let keyData = try Data(contentsOf: keyURL)
    #expect(keyData.count == 32)
    let keyAttributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((keyAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }
}
