import Foundation
import SQLiteNIO

actor SQLiteBackend {
  private var sessions: [UUID: SQLiteConnection] = [:]

  deinit {
    for connection in sessions.values {
      Task { try? await connection.close() }
    }
  }

  func testConnection(profile: ConnectionProfile) async throws -> ConnectionMetadata {
    let connection = try await open(profile)
    do {
      let metadata = try await fetchMetadata(using: connection, profile: profile)
      try await connection.close()
      return metadata
    } catch {
      try? await connection.close()
      throw error
    }
  }

  func connect(profile: ConnectionProfile) async throws -> ConnectionMetadata {
    await disconnect(profileID: profile.id)
    let connection = try await open(profile)
    sessions[profile.id] = connection
    do {
      return try await fetchMetadata(using: connection, profile: profile)
    } catch {
      sessions.removeValue(forKey: profile.id)
      try? await connection.close()
      throw error
    }
  }

  func disconnect(profileID: UUID) async {
    guard let connection = sessions.removeValue(forKey: profileID) else { return }
    try? await connection.close()
  }

  func loadSchema(profileID: UUID) async throws -> [SchemaObject] {
    guard let connection = sessions[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    let rows = try await connection.query(
      """
      SELECT
        'main' AS schema_name,
        object.name AS object_name,
        object.type AS object_type,
        COUNT(column_info.name) AS column_count
      FROM sqlite_schema AS object
      LEFT JOIN pragma_table_info(object.name) AS column_info
      WHERE object.type IN ('table', 'view')
        AND object.name NOT LIKE 'sqlite_%'
      GROUP BY object.name, object.type
      ORDER BY object.name
      """
    )
    return rows.compactMap { row in
      guard let name = row.column("object_name")?.string,
        let type = row.column("object_type")?.string,
        let count = row.column("column_count")?.integer
      else { return nil }
      return SchemaObject(
        schema: "main",
        name: name,
        kind: type == "view" ? .view : .table,
        columnCount: count
      )
    }
  }

  func execute(profileID: UUID, sql: String) async throws -> QueryExecutionResult {
    guard let connection = sessions[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    let clock = ContinuousClock()
    let start = clock.now
    let rows = try await connection.query(sql)
    let columns = rows.first?.columns.map(\.name) ?? []
    return QueryExecutionResult(
      table: QueryTableData(
        columns: columns,
        rows: rows.map { $0.columns.map { decodeCell($0.data) } }
      ),
      durationMilliseconds: BackendTime.milliseconds(from: start.duration(to: clock.now))
    )
  }

  private func open(_ profile: ConnectionProfile) async throws -> SQLiteConnection {
    let path = NSString(string: profile.database).expandingTildeInPath
    return try await SQLiteConnection.open(storage: .file(path: path))
  }

  private func fetchMetadata(using connection: SQLiteConnection, profile: ConnectionProfile)
    async throws -> ConnectionMetadata
  {
    let clock = ContinuousClock()
    let start = clock.now
    let rows = try await connection.query("PRAGMA encoding")
    let encoding = rows.first?.columns.first?.data.string ?? "UTF-8"
    return ConnectionMetadata(
      latencyMilliseconds: BackendTime.milliseconds(from: start.duration(to: clock.now)),
      serverVersion: SQLiteConnection.libraryVersionString(),
      serverEncoding: encoding,
      serverTimeZone: "Local values (no database time zone)",
      database: profile.database
    )
  }

  private func decodeCell(_ data: SQLiteData) -> QueryCellValue {
    switch data {
    case .integer(let value): .integer(Int64(value))
    case .float(let value): .decimal(String(value))
    case .text(let value): .text(value)
    case .blob(let value): .binary(byteCount: value.readableBytes)
    case .null: .null
    }
  }
}
