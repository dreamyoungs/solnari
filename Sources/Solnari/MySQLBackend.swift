import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

actor MySQLBackend {
  private var sessions: [UUID: MySQLConnection] = [:]

  deinit {
    for connection in sessions.values {
      connection.close().whenFailure { _ in }
    }
  }

  func testConnection(profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    let connection = try await makeConnection(profile: profile, password: password)
    do {
      let metadata = try await fetchMetadata(using: connection)
      try await connection.close().get()
      return metadata
    } catch {
      try? await connection.close().get()
      throw error
    }
  }

  func connect(profile: ConnectionProfile, password: String) async throws -> ConnectionMetadata {
    await disconnect(profileID: profile.id)
    let connection = try await makeConnection(profile: profile, password: password)
    sessions[profile.id] = connection
    do {
      return try await fetchMetadata(using: connection)
    } catch {
      sessions.removeValue(forKey: profile.id)
      try? await connection.close().get()
      throw error
    }
  }

  func disconnect(profileID: UUID) async {
    guard let connection = sessions.removeValue(forKey: profileID) else { return }
    try? await connection.close().get()
  }

  func loadSchema(profileID: UUID) async throws -> [SchemaObject] {
    guard let connection = sessions[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    let rows = try await connection.simpleQuery(
      """
      SELECT
        table_schema,
        table_name,
        table_type,
        COUNT(column_name) AS column_count
      FROM information_schema.columns
      JOIN information_schema.tables USING (table_schema, table_name)
      WHERE table_schema = DATABASE()
      GROUP BY table_schema, table_name, table_type
      ORDER BY table_name
      """
    ).get()

    return rows.compactMap { row in
      guard let schema = row.column("table_schema")?.string,
        let name = row.column("table_name")?.string,
        let type = row.column("table_type")?.string,
        let count = row.column("column_count")?.int
      else { return nil }
      return SchemaObject(
        schema: schema,
        name: name,
        kind: type == "VIEW" ? .view : .table,
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
    let rows = try await connection.query(sql).get()
    let columns = rows.first?.columnDefinitions.map(\.name) ?? []
    let values = rows.map { row in
      zip(row.columnDefinitions, row.values).map { definition, buffer in
        decodeCell(
          MySQLData(
            type: definition.columnType,
            format: row.format,
            buffer: buffer,
            isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)
          ),
          definition: definition
        )
      }
    }
    return QueryExecutionResult(
      table: QueryTableData(columns: columns, rows: values),
      durationMilliseconds: BackendTime.milliseconds(from: start.duration(to: clock.now))
    )
  }

  private func makeConnection(profile: ConnectionProfile, password: String) async throws
    -> MySQLConnection
  {
    let address = try SocketAddress.makeAddressResolvingHost(
      profile.host, port: profile.port
    )
    let connection = try await MySQLConnection.connect(
      to: address,
      username: profile.username,
      database: profile.database,
      password: password.isEmpty ? nil : password,
      tlsConfiguration: profile.requiresTLS ? .makeClientConfiguration() : nil,
      serverHostname: profile.requiresTLS ? profile.host : nil,
      on: MultiThreadedEventLoopGroup.singleton.any()
    ).get()
    do {
      _ = try await connection.simpleQuery("SET time_zone = '+00:00'").get()
      if profile.clientEncoding != "Automatic" {
        let supported = ["utf8mb4", "euckr", "latin1"]
        guard supported.contains(profile.clientEncoding) else {
          throw SolnariDatabaseError.incompleteConnection
        }
        _ = try await connection.simpleQuery("SET NAMES \(profile.clientEncoding)").get()
      }
      return connection
    } catch {
      try? await connection.close().get()
      throw error
    }
  }

  private func fetchMetadata(using connection: MySQLConnection) async throws
    -> ConnectionMetadata
  {
    let clock = ContinuousClock()
    let start = clock.now
    let rows = try await connection.simpleQuery(
      """
      SELECT
        VERSION() AS server_version,
        @@character_set_database AS server_encoding,
        @@session.time_zone AS server_time_zone,
        DATABASE() AS database_name
      """
    ).get()
    guard let row = rows.first,
      let version = row.column("server_version")?.string,
      let encoding = row.column("server_encoding")?.string,
      let timeZone = row.column("server_time_zone")?.string
    else { throw SolnariDatabaseError.invalidServerResponse }
    return ConnectionMetadata(
      latencyMilliseconds: BackendTime.milliseconds(from: start.duration(to: clock.now)),
      serverVersion: version,
      serverEncoding: encoding,
      serverTimeZone: timeZone,
      database: row.column("database_name")?.string ?? ""
    )
  }

  private func decodeCell(
    _ data: MySQLData, definition: MySQLProtocol.ColumnDefinition41
  ) -> QueryCellValue {
    guard data.buffer != nil else { return .null }
    switch data.type {
    case .tiny, .short, .long, .longlong, .int24, .year, .bit:
      if data.type == .tiny, definition.columnLength == 1, let value = data.bool {
        return .boolean(value)
      }
      if let value = data.int64 { return .integer(value) }
    case .float, .double, .decimal, .newdecimal:
      if let value = data.string { return .decimal(value) }
      if let value = data.decimal {
        return .decimal(NSDecimalNumber(decimal: value).stringValue)
      }
    case .timestamp, .timestamp2:
      if let value = data.date { return .instant(value) }
    case .datetime, .datetime2:
      if let value = data.date { return .localTimestamp(value) }
    case .date, .newdate:
      if let value = data.date { return .date(value) }
    case .blob, .tinyBlob, .mediumBlob, .longBlob:
      if definition.characterSet != .binary, let value = data.string {
        return .text(value)
      }
      return .binary(byteCount: data.buffer?.readableBytes ?? 0)
    case .geometry:
      return .binary(byteCount: data.buffer?.readableBytes ?? 0)
    default:
      break
    }
    return data.string.map(QueryCellValue.text)
      ?? .binary(byteCount: data.buffer?.readableBytes ?? 0)
  }
}
