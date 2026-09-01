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
