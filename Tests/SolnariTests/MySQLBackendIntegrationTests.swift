import Foundation
import Testing

@testable import Solnari

struct MySQLBackendIntegrationTests {
  @Test(
    "환경 변수가 있으면 실제 MySQL 연결, 스키마, 동적 쿼리를 검증한다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_TEST_MYSQL_HOST"] != nil,
      "SOLNARI_TEST_MYSQL_HOST를 설정하면 실행됩니다."
    )
  )
  func connectionSchemaAndDynamicQueryWhenDatabaseIsConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    let host = try #require(environment["SOLNARI_TEST_MYSQL_HOST"])
    let profile = ConnectionProfile(
      name: "MySQL integration test",
      database: environment["SOLNARI_TEST_MYSQL_DATABASE"] ?? "mysql",
      engine: .mysql,
      transport: .direct,
      host: host,
      port: Int(environment["SOLNARI_TEST_MYSQL_PORT"] ?? "3306") ?? 3306,
      username: environment["SOLNARI_TEST_MYSQL_USER"] ?? "root",
      requiresTLS: environment["SOLNARI_TEST_MYSQL_TLS"] == "true",
      clientEncoding: "utf8mb4"
    )
    let backend = DatabaseBackend()
    let metadata = try await backend.connect(
      profile: profile,
      password: environment["SOLNARI_TEST_MYSQL_PASSWORD"] ?? ""
    )
    #expect(!metadata.serverVersion.isEmpty)
    #expect(!metadata.serverEncoding.isEmpty)
    _ = try await backend.loadSchema(profileID: profile.id)
    let result = try await backend.execute(
      profileID: profile.id,
      sql: "SELECT 1 AS id, '솔나리' AS name, CAST(19.95 AS DECIMAL(5,2)) AS amount"
    )
    #expect(result.table.columns == ["id", "name", "amount"])
    #expect(result.table.rows.first?[0] == .integer(1))
    #expect(result.table.rows.first?[1] == .text("솔나리"))
    await backend.disconnect(profileID: profile.id)
  }
}
