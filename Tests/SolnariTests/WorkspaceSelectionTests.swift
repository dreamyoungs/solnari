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

  @Test("테이블 결과 셀은 실행하지 않고 편집기에 조건 쿼리를 생성한다")
  func resultCellGeneratesQueryInEditorAndFailuresClearOldResults() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariResultQueryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profile = sqliteProfile(
      name: "Result Query",
      database: directory.appendingPathComponent("result-query.db")
    )
    let setupBackend = DatabaseBackend()
    _ = try await setupBackend.connect(profile: profile, password: "")
    _ = try await setupBackend.execute(
      profileID: profile.id,
      sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT)"
    )
    _ = try await setupBackend.execute(
      profileID: profile.id,
      sql: "INSERT INTO items (id, title) VALUES (1, 'Solnari')"
    )
    await setupBackend.disconnectAll()

    let suiteName = "SolnariResultQueryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileStore = ConnectionProfileStore(defaults: defaults)
    try profileStore.save([profile])
    let workspace = WorkspaceModel(
      backend: DatabaseBackend(),
      profileStore: profileStore,
      passwordStore: LocalEncryptedPasswordStore(
        directoryURL: directory.appendingPathComponent("credentials", isDirectory: true)
      )
    )

    await workspace.connect(profileID: profile.id)
    let object = try #require(workspace.schemaObjects.first { $0.name == "items" })
    await workspace.openData(for: object)
    #expect(workspace.queryTable.rows.count == 1)
    #expect(workspace.querySourceObject == object)

    workspace.generateQueryFromResultCell(rowIndex: 0, columnIndex: 1, action: .equal)
    #expect(workspace.selectedTab?.sql.contains(#"WHERE "title" = 'Solnari'"#) == true)
    #expect(workspace.queryTable.rows.count == 1)

    workspace.useSQL("SELECT missing_column FROM items")
    await workspace.runCurrentQuery()
    #expect(workspace.queryTable == .empty)
    #expect(workspace.querySourceObject == nil)

    workspace.useSQL(#"SELECT * FROM "main"."items""#)
    await workspace.runCurrentQuery()
    #expect(workspace.querySourceObject == object)
    let profileIndex = try #require(workspace.connections.firstIndex { $0.id == profile.id })
    workspace.connections[profileIndex].accessLevel = .readOnly
    #expect(workspace.canGenerateDeleteQueryFromResult)
    workspace.generateQueryFromResultCell(rowIndex: 0, columnIndex: 0, action: .deleteMatching)
    #expect(workspace.selectedTab?.sql.contains(#"DELETE FROM "main"."items""#) == true)

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
