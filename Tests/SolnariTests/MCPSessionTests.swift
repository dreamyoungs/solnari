import Foundation
import Testing

@testable import Solnari

struct MCPSessionTests {
  @Test(
    "실제 PostgreSQL에서는 MCP 3개와 앱 세션이 서로 다른 DB 세션에서 실행된다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_TEST_POSTGRES_HOST"] != nil,
      "SOLNARI_TEST_POSTGRES_HOST를 설정하면 실행됩니다.")
  )
  func independentPostgresSessions() async throws {
    let environment = ProcessInfo.processInfo.environment
    let profile = ConnectionProfile(
      name: "MCP PostgreSQL", database: environment["SOLNARI_TEST_POSTGRES_DATABASE"] ?? "postgres",
      engine: .postgresql, transport: .direct,
      host: try #require(environment["SOLNARI_TEST_POSTGRES_HOST"]),
      port: Int(environment["SOLNARI_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432,
      username: environment["SOLNARI_TEST_POSTGRES_USER"] ?? "postgres",
      requiresTLS: environment["SOLNARI_TEST_POSTGRES_TLS"] == "true", clientEncoding: "UTF8",
      accessLevel: .readOnly)
    let backend = DatabaseBackend()
    let password = environment["SOLNARI_TEST_POSTGRES_PASSWORD"] ?? ""
    _ = try await backend.connect(profile: profile, password: password)
    var sessions: [UUID] = []
    for _ in 0..<3 {
      sessions.append(
        try await backend.openMCPSession(
          parentID: profile.id, password: password, requiredAccessLevel: .readOnly))
    }
    await #expect(throws: MCPAccessError.self) {
      try await backend.openMCPSession(parentID: profile.id, password: password)
    }
    let results = try await withThrowingTaskGroup(of: QueryExecutionResult.self) { group in
      for session in sessions + [profile.id] {
        group.addTask {
          try await backend.execute(
            profileID: session, sql: "SELECT pg_backend_pid() AS pid, pg_sleep(0.2)")
        }
      }
      var results: [QueryExecutionResult] = []
      for try await result in group { results.append(result) }
      return results
    }
    #expect(results.count == 4)
    #expect(Set(results.map { $0.table.rows[0][0] }).count == 4)
    await backend.disconnectAll()
  }

  @Test("전용 세션 열기에 실패해도 다음 요청의 슬롯은 복구된다")
  func failedOpenReleasesReservation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPOpenFailure-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("data.sqlite")
    let backup = directory.appendingPathComponent("backup.sqlite")
    let profile = ConnectionProfile(
      name: "Fixture", database: database.path, engine: .sqlite, transport: .direct,
      host: "", port: 0, username: "", requiresTLS: false, clientEncoding: "Automatic",
      accessLevel: .readWrite, mcpMaxConcurrentQueries: 1)
    let backend = DatabaseBackend()
    _ = try await backend.connect(profile: profile, password: "")
    try FileManager.default.moveItem(at: database, to: backup)
    try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) {
      try await backend.openMCPSession(parentID: profile.id, password: "")
    }
    try FileManager.default.removeItem(at: database)
    try FileManager.default.moveItem(at: backup, to: database)
    let session = try await backend.openMCPSession(parentID: profile.id, password: "")
    _ = try await backend.execute(profileID: session, sql: "SELECT 1")
    await backend.disconnectAll()
  }

  @Test("MCP 세션은 요청별로 분리되고 연결별 한도를 적용하며 부모 종료 시 모두 닫힌다")
  func isolatesSessionsAndBoundsConcurrentRequests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPSessions-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = ConnectionProfile(
      name: "Development", database: directory.appendingPathComponent("data.sqlite").path,
      engine: .sqlite, transport: .direct, host: "", port: 0, username: "",
      requiresTLS: false, clientEncoding: "Automatic", accessLevel: .readWrite)
    let backend = DatabaseBackend()
    _ = try await backend.connect(profile: profile, password: "")
    _ = try await backend.execute(
      profileID: profile.id, sql: "CREATE TEMP TABLE app_private (id INTEGER)")
    let sessions = try await withThrowingTaskGroup(of: UUID.self) { group in
      for _ in 0..<3 {
        group.addTask {
          try await backend.openMCPSession(
            parentID: profile.id, password: "", requiredAccessLevel: .readWrite)
        }
      }
      var ids: [UUID] = []
      for try await id in group { ids.append(id) }
      return ids
    }
    #expect(Set(sessions).count == 3)
    await #expect(throws: MCPAccessError.self) {
      try await backend.openMCPSession(
        parentID: profile.id, password: "", requiredAccessLevel: .readWrite)
    }
    _ = try await backend.execute(
      profileID: sessions[0], sql: "CREATE TEMP TABLE mcp_private (id INTEGER)")
    for target in [profile.id, sessions[1]] {
      await #expect(throws: (any Error).self) {
        try await backend.execute(profileID: target, sql: "SELECT * FROM mcp_private")
      }
    }
    await #expect(throws: (any Error).self) {
      try await backend.execute(profileID: sessions[0], sql: "SELECT * FROM app_private")
    }
    _ = try await backend.execute(
      profileID: profile.id, sql: "CREATE TABLE committed_notes (id INTEGER)")
    _ = try await backend.execute(profileID: sessions[0], sql: "BEGIN")
    _ = try await backend.execute(
      profileID: sessions[0], sql: "INSERT INTO committed_notes VALUES (1)")
    await backend.disconnect(profileID: sessions[0])
    let rolledBack = try await backend.execute(
      profileID: profile.id, sql: "SELECT * FROM committed_notes")
    #expect(rolledBack.table.rows.isEmpty)
    let replacement = try await backend.openMCPSession(
      parentID: profile.id, password: "", requiredAccessLevel: .readWrite)
    await #expect(throws: (any Error).self) {
      try await backend.execute(profileID: replacement, sql: "SELECT * FROM mcp_private")
    }
    let appResult = try await backend.execute(
      profileID: profile.id, sql: "SELECT * FROM app_private")
    #expect(appResult.table.rows.isEmpty)
    await backend.disconnect(profileID: profile.id)
    for session in [replacement] + Array(sessions.dropFirst()) {
      await #expect(throws: SolnariDatabaseError.self) {
        try await backend.execute(profileID: session, sql: "SELECT 1")
      }
    }
    await #expect(throws: (any Error).self) {
      try await backend.openMCPSession(
        parentID: profile.id, password: "", requiredAccessLevel: .readWrite)
    }
  }

  @Test("설정한 MCP 한도는 연결별로 독립적이며 권한 불일치 시 슬롯을 점유하지 않는다")
  func configuredLimitsAndPermissionMismatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPLimits-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DatabaseBackend()
    let profiles = (1...2).map { index in
      ConnectionProfile(
        name: "DB \(index)", database: directory.appendingPathComponent("db\(index).sqlite").path,
        engine: .sqlite, transport: .direct, host: "", port: 0, username: "",
        requiresTLS: false, clientEncoding: "Automatic", accessLevel: .readOnly,
        mcpMaxConcurrentQueries: 1)
    }
    for profile in profiles { _ = try await backend.connect(profile: profile, password: "") }
    for profile in profiles {
      await #expect(throws: SolnariDatabaseError.self) {
        try await backend.openMCPSession(
          parentID: profile.id, password: "", requiredAccessLevel: .readWrite)
      }
      let session = try await backend.openMCPSession(
        parentID: profile.id, password: "", requiredAccessLevel: .readOnly)
      await #expect(throws: MCPAccessError.self) {
        try await backend.openMCPSession(
          parentID: profile.id, password: "", requiredAccessLevel: .readOnly)
      }
      await #expect(throws: SolnariDatabaseError.self) {
        try await backend.execute(
          profileID: session, sql: "CREATE TABLE forbidden (id INTEGER)",
          requiredAccessLevel: .readWrite)
      }
    }
    await backend.disconnectAll()
  }
}
