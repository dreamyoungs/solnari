import Foundation
import Testing

@testable import Solnari

struct KeychainPasswordStoreTests {
  @Test("데이터베이스 비밀번호는 macOS Keychain에 저장하고 삭제할 수 있다")
  func passwordRoundTrip() throws {
    let store = KeychainPasswordStore()
    let profileID = UUID()
    let password = "solnari-keychain-validation-\(UUID().uuidString)"
    defer { try? store.delete(for: profileID) }

    try store.save(password, for: profileID)
    #expect(try store.password(for: profileID) == password)

    try store.delete(for: profileID)
    #expect(try store.password(for: profileID) == nil)
  }

  @Test("민감한 연결 profile을 동기화되지 않는 device-only Keychain에 저장한다")
  func sensitiveProfileRoundTrip() throws {
    let vault = KeychainConnectionProfileVault()
    let profile = ConnectionProfile(
      name: "Private profile",
      database: "database",
      engine: .postgresql,
      transport: .direct,
      host: "private.example.invalid",
      port: 5432,
      username: "developer",
      requiresTLS: true,
      clientEncoding: "UTF8"
    )
    defer { try? vault.delete(profileID: profile.id) }

    try vault.save(profile)
    let loaded = try #require(try vault.profile(for: profile.id))
    #expect(loaded.host == "private.example.invalid")
    #expect(loaded.status == .disconnected)

    try vault.delete(profileID: profile.id)
    #expect(try vault.profile(for: profile.id) == nil)
  }
}
