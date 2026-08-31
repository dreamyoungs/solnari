import Foundation
import PostgresNIO

actor PostgreSQLBackend {
  private struct Session: Sendable {
    let client: PostgresClient
    let runTask: Task<Void, Never>
  }

  private var sessions: [UUID: Session] = [:]

  deinit {
    for session in sessions.values {
      session.runTask.cancel()
    }
  }

  func testConnection(profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    let session = makeSession(profile: profile, password: password)
    defer { session.runTask.cancel() }
    return try await fetchMetadata(using: session.client)
  }

  func connect(profile: ConnectionProfile, password: String) async throws -> ConnectionMetadata {
    disconnect(profileID: profile.id)
    let session = makeSession(profile: profile, password: password)
    sessions[profile.id] = session

    do {
      return try await fetchMetadata(using: session.client)
    } catch {
      sessions.removeValue(forKey: profile.id)?.runTask.cancel()
      throw error
    }
  }

  func disconnect(profileID: UUID) {
    sessions.removeValue(forKey: profileID)?.runTask.cancel()
  }

  func loadSchema(profileID: UUID) async throws -> [SchemaObject] {
    guard let client = sessions[profileID]?.client else {
      throw SolnariDatabaseError.notConnected
    }

    let rows = try await client.query(
      """
      SELECT
        namespace.nspname AS schema_name,
        relation.relname AS object_name,
        relation.relkind::text AS object_kind,
        COUNT(attribute.attnum) FILTER (
          WHERE attribute.attnum > 0 AND NOT attribute.attisdropped
        ) AS column_count
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      LEFT JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = relation.oid
      WHERE relation.relkind IN ('r', 'p', 'v', 'm')
        AND namespace.nspname NOT IN ('pg_catalog', 'information_schema')
        AND namespace.nspname !~ '^pg_toast'
      GROUP BY namespace.nspname, relation.relname, relation.relkind
      ORDER BY namespace.nspname, relation.relname;
      """
    )

    var objects: [SchemaObject] = []
    for try await row in rows {
      let cells = Array(row)
      guard cells.count == 4 else { continue }
      let schema = try cells[0].decode(String.self)
      let name = try cells[1].decode(String.self)
      let relationKind = try cells[2].decode(String.self)
      let columnCount = try cells[3].decode(Int64.self)
      let kind: SchemaObjectKind
      switch relationKind {
      case "v": kind = .view
      case "m": kind = .materializedView
      default: kind = .table
      }
      objects.append(
        SchemaObject(
          schema: schema,
          name: name,
          kind: kind,
          columnCount: Int(clamping: columnCount)
        ))
    }
    return objects
  }

  func execute(profileID: UUID, sql: String) async throws -> QueryExecutionResult {
    guard let client = sessions[profileID]?.client else {
      throw SolnariDatabaseError.notConnected
    }

    let clock = ContinuousClock()
    let start = clock.now
    let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
    let columns = Array(rows.columns)
    var values: [[QueryCellValue]] = []

    for try await row in rows {
      values.append(zip(row, columns).map(decodeCell))
    }

    return QueryExecutionResult(
      table: QueryTableData(columns: columns.map(\.name), rows: values),
      durationMilliseconds: Self.milliseconds(from: start.duration(to: clock.now))
    )
  }

  private func makeSession(profile: ConnectionProfile, password: String) -> Session {
    let tls: PostgresClient.Configuration.TLS =
      profile.requiresTLS
      ? .require(.makeClientConfiguration()) : .prefer(.makeClientConfiguration())
    var configuration = PostgresClient.Configuration(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      password: password.isEmpty ? nil : password,
      database: profile.database.isEmpty ? nil : profile.database,
      tls: tls
    )
    configuration.options.connectTimeout = .seconds(8)
    configuration.options.maximumConnections = 4
    if profile.clientEncoding != "Automatic" {
      configuration.options.additionalStartupParameters.append(
        ("client_encoding", profile.clientEncoding))
    }
    if profile.effectiveAccessLevel == .readOnly {
      configuration.options.additionalStartupParameters.append(
        ("default_transaction_read_only", "on"))
      configuration.options.additionalStartupParameters.append(("statement_timeout", "30000"))
      configuration.options.additionalStartupParameters.append(("lock_timeout", "5000"))
    }

    let client = PostgresClient(configuration: configuration)
    let runTask = Task { await client.run() }
    return Session(client: client, runTask: runTask)
  }

  private func fetchMetadata(using client: PostgresClient) async throws -> ConnectionMetadata {
    let clock = ContinuousClock()
    let start = clock.now
    let rows = try await client.query(
      """
      SELECT
        current_setting('server_version') AS server_version,
        current_setting('server_encoding') AS server_encoding,
        current_setting('TimeZone') AS server_time_zone,
        current_database() AS database_name;
      """
    )
    let collected = try await rows.collect()
    guard let row = collected.first else {
      throw SolnariDatabaseError.invalidServerResponse
    }
    let cells = Array(row)
    guard cells.count == 4 else {
      throw SolnariDatabaseError.invalidServerResponse
    }
    return ConnectionMetadata(
      latencyMilliseconds: Self.milliseconds(from: start.duration(to: clock.now)),
      serverVersion: try cells[0].decode(String.self),
      serverEncoding: try cells[1].decode(String.self),
      serverTimeZone: try cells[2].decode(String.self),
      database: try cells[3].decode(String.self)
    )
  }

  private func decodeCell(_ pair: (PostgresCell, PostgresColumn)) -> QueryCellValue {
    let (cell, column) = pair
    guard cell.bytes != nil else { return .null }

    do {
      switch column.dataType {
      case .bool:
        return .boolean(try cell.decode(Bool.self))
      case .int2:
        return .integer(Int64(try cell.decode(Int16.self)))
      case .int4:
        return .integer(Int64(try cell.decode(Int32.self)))
      case .int8:
        return .integer(try cell.decode(Int64.self))
      case .float4:
        return .decimal(String(try cell.decode(Float.self)))
      case .float8:
        return .decimal(String(try cell.decode(Double.self)))
      case .numeric:
        let value = try cell.decode(Decimal.self)
        return .decimal(NSDecimalNumber(decimal: value).stringValue)
      case .timestamp:
        return .localTimestamp(try cell.decode(Date.self))
      case .timestamptz:
        return .instant(try cell.decode(Date.self))
      case .date:
        return .date(try cell.decode(Date.self))
      case .bytea:
        return .binary(byteCount: try cell.decode(ByteBuffer.self).readableBytes)
      case .uuid:
        return .text(try cell.decode(UUID.self).uuidString.lowercased())
      default:
        if let string = try? cell.decode(String.self) {
          return .text(string)
        }
        return .text(Self.hexDescription(cell.bytes))
      }
    } catch {
      return .text(Self.hexDescription(cell.bytes))
    }
  }

  private static func hexDescription(_ buffer: ByteBuffer?) -> String {
    guard let buffer else { return "NULL" }
    let prefix = buffer.readableBytesView.prefix(64).map { String(format: "%02x", $0) }.joined()
    let suffix = buffer.readableBytes > 64 ? "…" : ""
    return "0x\(prefix)\(suffix)"
  }

  private static func milliseconds(from duration: Duration) -> Int {
    let components = duration.components
    let seconds = components.seconds * 1_000
    let attoseconds = components.attoseconds / 1_000_000_000_000_000
    return Int(clamping: seconds + attoseconds)
  }
}
