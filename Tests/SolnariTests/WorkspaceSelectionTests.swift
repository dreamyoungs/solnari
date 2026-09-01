import Foundation
import Testing

@testable import Solnari

@MainActor
struct WorkspaceSelectionTests {
  @Test("연결을 전환하면 해당 연결의 스키마, 쿼리, 결과를 복원한다")
  func switchingConnectionsRestoresTheirWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = sqliteProfile(name: "First", database: directory.appendingPathComponent("first.db"))
    let second = sqliteProfile(
      name: "Second",
      database: directory.appendingPathComponent("second.db")
    )
    let setupBackend = DatabaseBackend()
    for (profile, table) in [(first, "first_items"), (second, "second_items")] {
      _ = try await setupBackend.connect(profile: profile, password: "")
      _ = try await setupBackend.execute(
        profileID: profile.id,
        sql: "CREATE TABLE \(table) (id INTEGER PRIMARY KEY)"
      )
    }
    await setupBackend.disconnectAll()

    let suiteName = "SolnariWorkspaceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileStore = ConnectionProfileStore(defaults: defaults)
    try profileStore.save([first, second])
    let workspace = WorkspaceModel(
      backend: DatabaseBackend(),
      profileStore: profileStore,
      passwordStore: LocalEncryptedPasswordStore(
        directoryURL: directory.appendingPathComponent("credentials", isDirectory: true)
      )
    )

    await workspace.connect(profileID: first.id)
    #expect(workspace.schemaNames == ["main"])
    #expect(workspace.schemaObjects.map(\.name) == ["first_items"])
    workspace.useSQL("SELECT 'first' AS workspace")
    await workspace.runCurrentQuery()
    #expect(workspace.queryTable.rows == [[.text("first")]])

    workspace.selectedConnectionID = second.id
    await workspace.activateSelectedConnection()
    #expect(workspace.schemaNames == ["main"])
    #expect(workspace.schemaObjects.map(\.name) == ["second_items"])
    workspace.useSQL("SELECT 'second' AS workspace")
    await workspace.runCurrentQuery()
    #expect(workspace.queryTable.rows == [[.text("second")]])

    workspace.selectedConnectionID = first.id
    await workspace.activateSelectedConnection()
    #expect(workspace.schemaObjects.map(\.name) == ["first_items"])
    #expect(workspace.selectedTab?.sql == "SELECT 'first' AS workspace")
    #expect(workspace.queryTable.rows == [[.text("first")]])

    await workspace.suspendConnections()
  }

  private func sqliteProfile(name: String, database: URL) -> ConnectionProfile {
    ConnectionProfile(
      name: name,
      database: database.path,
      engine: .sqlite,
      transport: .direct,
      host: "",
      port: 0,
      username: "",
      requiresTLS: false,
      clientEncoding: "Automatic"
    )
  }
}
