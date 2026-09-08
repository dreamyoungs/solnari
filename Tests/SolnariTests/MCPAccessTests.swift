import Foundation
import Testing

@testable import Solnari

@MainActor
struct MCPAccessTests {
  @Test("MCP cell은 UTF-8 경계를 보존하며 16 KiB로 제한한다")
  func boundsLargeUTF8Cells() {
    let cell = MCPQueryCell(.text(String(repeating: "가", count: 6_000)))

    #expect(cell.truncated)
    #expect(cell.value?.utf8.count ?? 0 <= 16_384)
    #expect(cell.value?.hasSuffix("�") == false)
  }

  @Test("완료된 쓰기의 응답이 크면 실패 대신 잘린 성공 결과를 반환한다")
  func largeWriteResponseKeepsExecutionSuccess() throws {
    let cell = MCPQueryCell(.text(String(repeating: "x", count: 16_384)))
    let response = MCPQuerySnapshot(
      columns: ["value"], rows: Array(repeating: [cell], count: 200), returnedRowCount: 200,
      truncated: false, durationMilliseconds: 12)
    let encoded = try MCPAccessController.encodeExecutedQuery(response)
    #expect(encoded.utf8.count < 2_000_000)
    let decoded = try JSONDecoder().decode(MCPQuerySnapshot.self, from: Data(encoded.utf8))
    #expect(decoded.truncated)
    #expect(decoded.rows.isEmpty)
    #expect(decoded.durationMilliseconds == 12)
  }

  @Test("MCP 쓰기는 선택한 쓰기 허용 연결에서만 실행하고 실제 세션 권한도 검증한다")
  func writeQueriesRespectSelectionAndSessionPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariMCPWriteTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = ConnectionProfile(
      name: "Writable fixture", database: directory.appendingPathComponent("write.sqlite").path,
      engine: .sqlite, transport: .direct, host: "", port: 0, username: "", requiresTLS: false,
      clientEncoding: "Automatic", accessLevel: .readWrite)
    let readOnly = ConnectionProfile(
      name: "Read-only fixture", database: profile.database,
      engine: .sqlite, transport: .direct, host: "", port: 0, username: "", requiresTLS: false,
      clientEncoding: "Automatic", accessLevel: .readOnly)
    let suiteName = "SolnariMCPWriteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([profile, readOnly])
    let workspace = WorkspaceModel(
      backend: DatabaseBackend(), profileStore: store,
      passwordStore: LocalEncryptedPasswordStore(
        directoryURL: directory.appendingPathComponent("vault")))
    await workspace.connect(profileID: profile.id)
    _ = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT)",
      maximumRows: 10)
    #expect(workspace.schemaObjects.contains { $0.name == "notes" })
    _ = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "INSERT INTO notes VALUES (1, 'original')", maximumRows: 10)
    _ = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "UPDATE notes SET title = 'updated' WHERE id = 1",
      maximumRows: 10)
    let updated = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "SELECT title FROM notes", maximumRows: 10)
    #expect(updated.rows.first?.first?.value == "updated")
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: readOnly.id, sql: "DELETE FROM notes", maximumRows: 10)
    }

    await workspace.connect(profileID: readOnly.id)
    workspace.selectedConnectionID = readOnly.id
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: readOnly.id, sql: "DELETE FROM notes", maximumRows: 10)
    }
    let index = try #require(workspace.connections.firstIndex { $0.id == readOnly.id })
    workspace.connections[index].accessLevel = .migration
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: readOnly.id, sql: "DELETE FROM notes", maximumRows: 10)
    }
    // 화면의 권한 값만 바뀌어도 이미 연결된 읽기 전용 DB 세션은 쓰기를 허용하지 않습니다.
    workspace.connections[index].accessLevel = .readWrite
    await #expect(throws: SolnariDatabaseError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: readOnly.id, sql: "DELETE FROM notes", maximumRows: 10)
    }
    workspace.connections[index].accessLevel = .readOnly
    let unchanged = try await workspace.mcpExecuteReadOnlyQuery(
      sql: "SELECT title FROM notes", maximumRows: 10)
    #expect(unchanged.rows.first?.first?.value == "updated")
    workspace.selectedConnectionID = profile.id
    let writableIndex = try #require(workspace.connections.firstIndex { $0.id == profile.id })
    workspace.connections[writableIndex].accessLevel = .readOnly
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: profile.id, sql: "DELETE FROM notes", maximumRows: 10)
    }
    workspace.connections[writableIndex].accessLevel = .readWrite
    _ = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "DELETE FROM notes WHERE id = 1", maximumRows: 10)
    let deleted = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "SELECT title FROM notes", maximumRows: 10)
    #expect(deleted.returnedRowCount == 0)
    _ = try await workspace.mcpExecuteQuery(
      connectionID: profile.id, sql: "DROP TABLE notes", maximumRows: 10)
    #expect(!workspace.schemaObjects.contains { $0.name == "notes" })
    await workspace.suspendConnections()
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: profile.id, sql: "CREATE TABLE denied (id INTEGER)", maximumRows: 10)
    }
  }

  @Test("MCP는 현재 연결된 읽기 전용 프로필의 조회만 허용한다")
  func allowsOnlySelectedConnectedReadOnlyQueries() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariMCPTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appendingPathComponent("mcp.sqlite")
    let writableProfile = ConnectionProfile(
      name: "MCP fixture",
      database: databaseURL.path,
      engine: .sqlite,
      transport: .direct,
      host: "",
      port: 0,
      username: "",
      requiresTLS: false,
      clientEncoding: "Automatic",
      accessLevel: .readWrite
    )
    let setupBackend = DatabaseBackend()
    _ = try await setupBackend.connect(profile: writableProfile, password: "")
    _ = try await setupBackend.execute(
      profileID: writableProfile.id,
      sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
    )
    _ = try await setupBackend.execute(
      profileID: writableProfile.id,
      sql: "INSERT INTO notes (title) VALUES ('safe preview')"
    )
    await setupBackend.disconnectAll()

    var readOnlyProfile = writableProfile
    readOnlyProfile.accessLevel = .readOnly
    let suiteName = "SolnariMCPTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileStore = ConnectionProfileStore(defaults: defaults)
    try profileStore.save([readOnlyProfile])
    let workspace = WorkspaceModel(
      backend: DatabaseBackend(),
      profileStore: profileStore,
      passwordStore: LocalEncryptedPasswordStore(
        directoryURL: directory.appendingPathComponent("credentials", isDirectory: true)
      )
    )

    await workspace.connect(profileID: readOnlyProfile.id)
    #expect(workspace.selectedConnection?.status == .connected)

    let schema = try await workspace.mcpSchemaSnapshot()
    #expect(schema.contains { $0.name == "notes" && $0.kind == .table })

    let result = try await workspace.mcpExecuteReadOnlyQuery(
      sql: "SELECT id, title FROM notes LIMIT 10",
      maximumRows: 10
    )
    #expect(result.columns == ["id", "title"])
    #expect(result.returnedRowCount == 1)
    #expect(result.rows[0][0].kind == "integer")
    #expect(result.rows[0][1].value == "safe preview")

    await #expect(throws: SolnariDatabaseError.self) {
      try await workspace.mcpExecuteReadOnlyQuery(
        sql: "DELETE FROM notes",
        maximumRows: 10
      )
    }

    workspace.connections[0].accessLevel = .readWrite
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteReadOnlyQuery(
        sql: "SELECT id FROM notes LIMIT 1",
        maximumRows: 1
      )
    }
    await workspace.suspendConnections()
  }
}
