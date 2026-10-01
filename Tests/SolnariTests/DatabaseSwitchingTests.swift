import Foundation
import Testing

@testable import Solnari

@MainActor
struct DatabaseSwitchingTests {
  @Test(
    "DB 전환은 작업을 복원하고 기본 DB를 보존하며 오래된 MCP 쓰기 대상을 거부한다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_TEST_POSTGRES_SECOND_DATABASE"] != nil,
      "두 PostgreSQL 테스트 DB를 설정하면 실행됩니다."
    ),
    arguments: [DatabaseAccessLevel.readWrite, .readOnly]
  )
  func switchingRestoresWorkspacesAndPreservesConnectionIdentity(access: DatabaseAccessLevel)
    async throws
  {
    let environment = ProcessInfo.processInfo.environment
    let firstDatabase = try #require(environment["SOLNARI_TEST_POSTGRES_DATABASE"])
    let secondDatabase = try #require(environment["SOLNARI_TEST_POSTGRES_SECOND_DATABASE"])
    let profile = ConnectionProfile(
      name: "Database switching fixture", database: firstDatabase,
      engine: .postgresql, transport: .direct,
      host: try #require(environment["SOLNARI_TEST_POSTGRES_HOST"]),
      port: Int(environment["SOLNARI_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432,
      username: environment["SOLNARI_TEST_POSTGRES_USER"] ?? "postgres",
      requiresTLS: environment["SOLNARI_TEST_POSTGRES_TLS"] == "true",
      clientEncoding: "UTF8", accessLevel: access)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariDatabaseSwitchTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "SolnariDatabaseSwitchTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([profile])
    let passwords = LocalEncryptedPasswordStore(directoryURL: directory)
    try passwords.save(environment["SOLNARI_TEST_POSTGRES_PASSWORD"] ?? "", for: profile.id)
    let backend = DatabaseBackend()
    let workspace = WorkspaceModel(backend: backend, profileStore: store, passwordStore: passwords)
    await workspace.connect(profileID: profile.id)
    #expect(workspace.canSwitchDatabase)
    await workspace.loadAvailableDatabases()
    #expect(workspace.availableDatabases[profile.id]?.contains(firstDatabase) == true)
    #expect(workspace.availableDatabases[profile.id]?.contains(secondDatabase) == true)
    workspace.useSQL("SELECT current_database() AS database, 'first' AS marker")
    await workspace.runCurrentQuery()
    let firstSQL = workspace.selectedTab?.sql
    let firstTabID = workspace.selectedTabID
    let firstResult = workspace.queryTable
    let firstSessionID = try #require(workspace.selectedDatabaseSessionID)

    // Invalid target leaves the original live session, editor and results intact.
    let failureStartedAt = ContinuousClock.now
    await workspace.switchDatabase(to: "solnari_missing_\(UUID().uuidString)")
    #expect(ContinuousClock.now - failureStartedAt < .seconds(12))
    #expect(workspace.presentedError != nil)
    #expect(workspace.selectedConnection?.database == firstDatabase)
    #expect(workspace.selectedDatabaseSessionID == firstSessionID)
    #expect(workspace.selectedTabID == firstTabID)
    #expect(workspace.queryTable == firstResult)
    let stillConnected = try await backend.execute(
      profileID: firstSessionID, sql: "SELECT current_database()", requiredAccessLevel: access)
    #expect(stillConnected.table.rows.first?.first == .text(firstDatabase))
    workspace.presentedError = nil

    await workspace.switchDatabase(to: secondDatabase)
    #expect(workspace.presentedError == nil)
    #expect(workspace.selectedConnectionID == profile.id)
    #expect(workspace.connections.count == 1)
    #expect(workspace.selectedConnection?.database == secondDatabase)
    #expect(workspace.selectedDatabaseSessionID != firstSessionID)
    #expect(workspace.queryTable == .empty)
    #expect(try store.load().first?.database == firstDatabase)
    await #expect(throws: MCPAccessError.self) {
      try await workspace.mcpExecuteQuery(
        connectionID: firstSessionID, sql: "SELECT current_database()", maximumRows: 1)
    }
    // The replaced session is closed rather than retained as an extra live connection.
    await #expect(throws: SolnariDatabaseError.self) {
      try await backend.execute(profileID: firstSessionID, sql: "SELECT 1")
    }
    let secondSessionID = try #require(workspace.selectedDatabaseSessionID)
    let second: MCPQuerySnapshot
    if access == .readWrite {
      second = try await workspace.mcpExecuteQuery(
        connectionID: secondSessionID, sql: "SELECT current_database()", maximumRows: 1)
    } else {
      second = try await workspace.mcpExecuteReadOnlyQuery(
        sql: "SELECT current_database()", maximumRows: 1)
      await #expect(throws: SolnariDatabaseError.self) {
        try await backend.execute(
          profileID: secondSessionID, sql: "SELECT 1", requiredAccessLevel: .readWrite)
      }
    }
    #expect(second.rows.first?.first?.value == secondDatabase)
    workspace.useSQL("SELECT current_database() AS database, 'second' AS marker")
    await workspace.runCurrentQuery()
    let secondSQL = workspace.selectedTab?.sql
    let secondTabID = workspace.selectedTabID
    let secondResult = workspace.queryTable

    let running = Task {
      if access == .readWrite {
        return try await workspace.mcpExecuteQuery(
          connectionID: secondSessionID, sql: "SELECT pg_sleep(0.2)", maximumRows: 1)
      }
      return try await workspace.mcpExecuteReadOnlyQuery(
        sql: "SELECT pg_sleep(0.2)", maximumRows: 1)
    }
    for _ in 0..<20 {
      if workspace.isRunning { break }
      await Task.yield()
    }
    #expect(workspace.isRunning)
    #expect(!workspace.canSwitchDatabase)
    await workspace.switchDatabase(to: firstDatabase)
    #expect(workspace.selectedConnection?.database == secondDatabase)
    _ = try await running.value

    await workspace.switchDatabase(to: firstDatabase)
    #expect(workspace.selectedTab?.sql == firstSQL)
    #expect(workspace.selectedTabID == firstTabID)
    #expect(workspace.queryTable == firstResult)
    await workspace.switchDatabase(to: secondDatabase)
    #expect(workspace.selectedTab?.sql == secondSQL)
    #expect(workspace.selectedTabID == secondTabID)
    #expect(workspace.queryTable == secondResult)
    // Reconnect and screen-lock cleanup continue to target the currently opened DB.
    await workspace.connect(profileID: profile.id)
    await workspace.runCurrentQuery()
    #expect(workspace.queryTable.rows.first?.first == .text(secondDatabase))
    #expect(try store.load().first?.database == firstDatabase)
    await workspace.suspendConnections()
    #expect(!workspace.canSwitchDatabase)
    await #expect(throws: SolnariDatabaseError.self) {
      try await backend.execute(
        profileID: try #require(workspace.selectedDatabaseSessionID), sql: "SELECT 1")
    }
    workspace.resumeConnectionOperations()
    await workspace.activateSelectedConnection()
    #expect(workspace.selectedConnection?.database == secondDatabase)
    await workspace.runCurrentQuery()
    #expect(workspace.queryTable.rows.first?.first == .text(secondDatabase))
    await workspace.suspendConnections()
  }
}
