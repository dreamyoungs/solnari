import Foundation
import Testing

@testable import Solnari

struct SQLiteBackendIntegrationTests {
  @Test("SQLite 파일 연결, 스키마 탐색, 쿼리 실행을 실제로 검증한다")
  func fileConnectionSchemaAndQuery() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("한국어.sqlite")
    let profile = ConnectionProfile(
      name: "로컬 SQLite",
      database: databaseURL.path,
      engine: .sqlite,
      transport: .direct,
      host: "",
      port: 0,
      username: "",
      requiresTLS: false,
      clientEncoding: "Automatic"
    )
    let backend = DatabaseBackend()

    let metadata = try await backend.connect(profile: profile, password: "")
    #expect(metadata.serverEncoding == "UTF-8")
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))

    _ = try await backend.execute(
      profileID: profile.id,
      sql: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
    )
    _ = try await backend.execute(
      profileID: profile.id,
      sql: "INSERT INTO people (name) VALUES ('솔나리')"
    )
    let result = try await backend.execute(
      profileID: profile.id,
      sql: "SELECT id, name FROM people"
    )
    #expect(result.table.columns == ["id", "name"])
    #expect(result.table.rows == [[.integer(1), .text("솔나리")]])

    let schema = try await backend.loadSchema(profileID: profile.id)
    #expect(schema.contains { $0.name == "people" && $0.columnCount == 2 })
    await backend.disconnect(profileID: profile.id)
  }
}
