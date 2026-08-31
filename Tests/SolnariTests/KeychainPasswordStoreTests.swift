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
}
