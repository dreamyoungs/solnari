import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

actor MySQLBackend {
  private var sessions: [UUID: MySQLConnection] = [:]

  private struct IndexAccumulator {
    let name: String
    let isUnique: Bool
    let isPrimary: Bool
    let method: String?
    var columns: [String]
  }

  private struct ConstraintAccumulator {
    let name: String
    let kind: SchemaConstraintKind
    let referencedSchema: String?
    let referencedTable: String?
    var columns: [String]
    var referencedColumns: [String]
  }

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

  func loadSchemaObjectDetails(profileID: UUID, object: SchemaObject) async throws
    -> SchemaObjectDetails
  {
    guard let connection = sessions[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    let binds = [MySQLData(string: object.schema), MySQLData(string: object.name)]
    let columnRows = try await connection.query(
      """
      SELECT
        ordinal_position,
        column_name,
        column_type,
        is_nullable,
        column_default,
        character_set_name,
        collation_name,
        column_comment,
        column_key
      FROM information_schema.columns
      WHERE table_schema = ? AND table_name = ?
      ORDER BY ordinal_position
      """,
      binds
    ).get()
    let columns = columnRows.compactMap { row -> SchemaColumn? in
      guard let ordinal = row.column("ordinal_position")?.int,
        let name = row.column("column_name")?.string,
        let dataType = row.column("column_type")?.string,
        let nullable = row.column("is_nullable")?.string
      else { return nil }
      return SchemaColumn(
        ordinalPosition: ordinal,
        name: name,
        dataType: dataType,
        isNullable: nullable == "YES",
        defaultValue: row.column("column_default")?.string,
        characterSet: row.column("character_set_name")?.string,
        collation: row.column("collation_name")?.string,
        comment: row.column("column_comment")?.string,
        isPrimaryKey: row.column("column_key")?.string == "PRI"
      )
    }

    let indexRows = try await connection.query(
      """
      SELECT index_name, non_unique, index_type, column_name
      FROM information_schema.statistics
      WHERE table_schema = ? AND table_name = ?
      ORDER BY index_name, seq_in_index
      """,
      binds
    ).get()
    var indexOrder: [String] = []
    var indexAccumulators: [String: IndexAccumulator] = [:]
    for row in indexRows {
      guard let name = row.column("index_name")?.string else { continue }
      if indexAccumulators[name] == nil {
        indexOrder.append(name)
        indexAccumulators[name] = IndexAccumulator(
          name: name,
          isUnique: row.column("non_unique")?.int == 0,
          isPrimary: name == "PRIMARY",
          method: row.column("index_type")?.string,
          columns: []
        )
      }
      if let column = row.column("column_name")?.string {
        indexAccumulators[name]?.columns.append(column)
      }
    }
    let indexes = indexOrder.compactMap { name -> SchemaIndex? in
      guard let index = indexAccumulators[name] else { return nil }
      return SchemaIndex(
        name: index.name,
        columns: index.columns,
        isUnique: index.isUnique,
        isPrimary: index.isPrimary,
        method: index.method
      )
    }

    let constraintRows = try await connection.query(
      """
      SELECT
        table_constraint.constraint_name,
        table_constraint.constraint_type,
        key_column.column_name,
        key_column.referenced_table_schema,
        key_column.referenced_table_name,
        key_column.referenced_column_name
      FROM information_schema.table_constraints AS table_constraint
      LEFT JOIN information_schema.key_column_usage AS key_column
        ON key_column.constraint_schema = table_constraint.constraint_schema
        AND key_column.table_schema = table_constraint.table_schema
        AND key_column.table_name = table_constraint.table_name
        AND key_column.constraint_name = table_constraint.constraint_name
      WHERE table_constraint.table_schema = ? AND table_constraint.table_name = ?
      ORDER BY table_constraint.constraint_name, key_column.ordinal_position
      """,
      binds
    ).get()
    var constraintOrder: [String] = []
    var constraintAccumulators: [String: ConstraintAccumulator] = [:]
    for row in constraintRows {
      guard let name = row.column("constraint_name")?.string,
        let type = row.column("constraint_type")?.string
      else { continue }
      if constraintAccumulators[name] == nil {
        constraintOrder.append(name)
        constraintAccumulators[name] = ConstraintAccumulator(
          name: name,
          kind: Self.constraintKind(type),
          referencedSchema: row.column("referenced_table_schema")?.string,
          referencedTable: row.column("referenced_table_name")?.string,
          columns: [],
          referencedColumns: []
        )
      }
      if let column = row.column("column_name")?.string {
        constraintAccumulators[name]?.columns.append(column)
      }
      if let referencedColumn = row.column("referenced_column_name")?.string {
        constraintAccumulators[name]?.referencedColumns.append(referencedColumn)
      }
    }
    let constraints = constraintOrder.compactMap { name -> SchemaConstraint? in
      guard let constraint = constraintAccumulators[name] else { return nil }
      return SchemaConstraint(
        name: constraint.name,
        kind: constraint.kind,
        columns: constraint.columns,
        referencedSchema: constraint.referencedSchema,
        referencedTable: constraint.referencedTable,
        referencedColumns: constraint.referencedColumns,
        definition: nil
      )
    }

    var definition: String?
    if object.kind == .view {
      let rows = try await connection.query(
        """
        SELECT view_definition
        FROM information_schema.views
        WHERE table_schema = ? AND table_name = ?
        """,
        binds
      ).get()
      definition = rows.first?.column("view_definition")?.string
    }

    return SchemaObjectDetails(
      object: object,
      columns: columns,
      indexes: indexes,
      constraints: constraints,
      definition: definition
    )
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
      if profile.effectiveAccessLevel == .readOnly {
        _ = try await connection.simpleQuery("SET SESSION transaction_read_only = ON").get()
      }
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

  private static func constraintKind(_ value: String) -> SchemaConstraintKind {
    switch value {
    case "PRIMARY KEY": .primaryKey
    case "FOREIGN KEY": .foreignKey
    case "UNIQUE": .unique
    case "CHECK": .check
    default: .other
    }
  }
}
