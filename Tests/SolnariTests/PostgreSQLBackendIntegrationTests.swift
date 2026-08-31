import Foundation
import Testing

@testable import Solnari

struct PostgreSQLBackendIntegrationTests {
  @Test(
    "환경 변수가 있으면 실제 PostgreSQL 연결, 스키마, 동적 쿼리를 검증한다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_TEST_POSTGRES_HOST"] != nil,
      "SOLNARI_TEST_POSTGRES_HOST를 설정하면 실행됩니다."
    )
  )
  func connectionSchemaAndDynamicQueryWhenDatabaseIsConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    let host = try #require(environment["SOLNARI_TEST_POSTGRES_HOST"])

    let profile = ConnectionProfile(
      name: "Integration test",
      database: environment["SOLNARI_TEST_POSTGRES_DATABASE"] ?? "postgres",
      engine: .postgresql,
      transport: .direct,
      host: host,
      port: Int(environment["SOLNARI_TEST_POSTGRES_PORT"] ?? "5432") ?? 5432,
      username: environment["SOLNARI_TEST_POSTGRES_USER"] ?? "postgres",
      requiresTLS: environment["SOLNARI_TEST_POSTGRES_TLS"] == "true",
      clientEncoding: "UTF8"
    )
    let backend = PostgreSQLBackend()
    let password = environment["SOLNARI_TEST_POSTGRES_PASSWORD"] ?? ""

    let metadata = try await backend.connect(profile: profile, password: password)
    #expect(!metadata.serverVersion.isEmpty)
    #expect(!metadata.serverEncoding.isEmpty)

    _ = try await backend.loadSchema(profileID: profile.id)
    let result = try await backend.execute(
      profileID: profile.id,
      sql: """
        SELECT
          1::bigint AS id,
          true AS enabled,
          19.95::numeric AS amount,
          '솔나리'::text AS name,
          TIMESTAMPTZ '2026-08-31 12:00:00+09' AS server_time,
          TIMESTAMP '2026-08-31 12:00:00' AS local_time,
          DATE '2026-08-31' AS calendar_date
        """
    )
    #expect(
      result.table.columns == [
        "id", "enabled", "amount", "name", "server_time", "local_time", "calendar_date",
      ])
    #expect(result.table.rows.count == 1)
    #expect(result.table.rows[0][0] == .integer(1))
    #expect(result.table.rows[0][1] == .boolean(true))
    #expect(result.table.rows[0][2] == .decimal("19.95"))
    #expect(result.table.rows[0][3] == .text("솔나리"))
    if case .instant = result.table.rows[0][4] {
    } else {
      Issue.record("타입이 지정된 timestamp with time zone 값이어야 합니다.")
    }
    if case .localTimestamp = result.table.rows[0][5] {
    } else {
      Issue.record("시간대 없는 timestamp 값이어야 합니다.")
    }
    if case .date = result.table.rows[0][6] {
    } else {
      Issue.record("date 값이어야 합니다.")
    }

    await backend.disconnect(profileID: profile.id)
  }
}
