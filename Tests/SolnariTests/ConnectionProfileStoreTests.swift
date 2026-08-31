import Foundation
import Testing

@testable import Solnari

struct ConnectionProfileStoreTests {
  @Test("연결 프로필은 사용자가 입력한 이름을 보존하고 런타임 상태를 초기화한다")
  func profileRoundTripPreservesUserNameAndResetsRuntimeState() throws {
    let suiteName = "SolnariTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConnectionProfileStore(defaults: defaults)
    let profile = ConnectionProfile(
      name: "민석의 개발 DB",
      database: "solnari_test",
      engine: .postgresql,
      transport: .direct,
      host: "127.0.0.1",
      port: 5432,
      username: "solnari",
      requiresTLS: false,
      clientEncoding: "UTF8",
      status: .connected,
      latency: 12,
      serverVersion: "17.2",
      serverEncoding: "UTF8",
      serverTimeZone: "Asia/Seoul"
    )

    try store.save([profile])
    let loaded = try #require(store.load().first)

    #expect(loaded.id == profile.id)
    #expect(loaded.name == "민석의 개발 DB")
    #expect(loaded.host == "127.0.0.1")
    #expect(loaded.status == .disconnected)
    #expect(loaded.latency == nil)
    #expect(loaded.serverVersion == nil)
  }

  @Test("연결 초안은 잘못된 포트와 아직 지원하지 않는 엔진을 거부한다")
  func draftRejectsUnsupportedAndInvalidConnections() {
    var draft = ConnectionDraft()
    draft.name = "Local"
    draft.host = "localhost"
    draft.user = "postgres"
    draft.port = "70000"
    #expect(!draft.isValid)
    #expect(throws: (any Error).self) { try draft.makeProfile() }

    draft.port = "5432"
    draft.engine = .mysql
    #expect(!draft.isValid)
    #expect(throws: (any Error).self) { try draft.makeProfile() }
  }
}
