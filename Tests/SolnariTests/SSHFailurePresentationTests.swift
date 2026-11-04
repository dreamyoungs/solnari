import Foundation
import Testing

@testable import Solnari

@MainActor
struct SSHFailurePresentationTests {
  @Test("SSH 단절은 해당 연결만 실패로 표시하고 실행 버튼으로 SQL을 재시도하지 않는다")
  func disconnectedSSHRequiresManualReconnect() async throws {
    let suite = "SSHFailurePresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var first = sshProfile(name: "First")
    first.status = .connected
    var second = sshProfile(name: "Second")
    second.status = .connected
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([first, second])
    let model = WorkspaceModel(
      backend: DatabaseBackend(
        transports: ConnectionTransportManager(
          executables: TransportExecutables(ssh: "/nonexistent/solnari-test-ssh"))),
      profileStore: store,
      passwordStore: LocalEncryptedPasswordStore(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)))
    // 저장 프로필은 상태를 초기화하므로 실행 중인 두 연결의 상태를 재현합니다.
    for index in model.connections.indices { model.connections[index].status = .connected }
    model.selectedConnectionID = first.id
    model.useSQL("SELECT 1")
    model.recordConnectionFailure(SolnariDatabaseError.sshTunnelDisconnected, profileID: first.id)
    let message = SolnariDatabaseError.sshTunnelDisconnected.localizedDescription
    #expect(model.selectedConnection?.status == .failed)
    #expect(model.connections.first { $0.id == second.id }?.status == .connected)
    #expect(model.executionFailure == message)
    await model.runCurrentQuery()
    #expect(model.presentedError == message)
    #expect(model.executionFailure == message)
    #expect(model.queryTable == .empty)
    #expect(model.selectedConnection?.status == .failed)

    // 명시적인 재연결에서는 이전 단절 표시를 지우고 연결을 새로 시도합니다.
    await model.connect(profileID: first.id)
    #expect(model.executionFailure == nil)
    #expect(model.presentedError != message)
    await model.suspendConnections()
  }

  @Test("일반 SQL 오류는 정상 연결을 실패로 바꾸지 않는다")
  func queryErrorKeepsConnectionStatus() throws {
    let suite = "SSHSQLFailureTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = sshProfile(name: "SQL error")
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([profile])
    let model = WorkspaceModel(profileStore: store)
    model.connections[0].status = .connected
    model.recordConnectionFailure(
      SolnariDatabaseError.queryNotAllowedForAccessLevel, profileID: profile.id)
    #expect(model.selectedConnection?.status == .connected)
    #expect(model.executionFailure == nil)
  }

  @Test("SSH 단절 상세 오류는 한국어와 영어 리소스에서 조회된다")
  func errorLocalization() throws {
    let key = SolnariDatabaseError.sshTunnelDisconnected.localizedDescription
    for language in ["ko", "en"] {
      let path = try #require(SolnariResources.bundle.path(forResource: language, ofType: "lproj"))
      let bundle = try #require(Bundle(path: path))
      let message = bundle.localizedString(forKey: key, value: nil, table: nil)
      if language == "ko" {
        #expect(message.contains("SSH 터널이 끊겼습니다"))
        #expect(message.contains("자동으로 재실행하지 않습니다"))
        #expect(!message.contains("The connection path failed"))
      } else {
        #expect(message == key)
      }
    }
  }

  private func sshProfile(name: String) -> ConnectionProfile {
    ConnectionProfile(
      name: name, database: "test", engine: .postgresql, transport: .ssh,
      host: "127.0.0.1", port: 5432, username: "test", requiresTLS: false, clientEncoding: "UTF8",
      ssh: SSHConfiguration(host: "bastion.example.test", port: 22, username: "test"))
  }
}
