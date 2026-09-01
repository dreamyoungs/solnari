import Foundation
import SQLiteNIO

actor SQLiteBackend {
  private var sessions: [UUID: SQLiteConnection] = [:]

  private struct IndexAccumulator {
    let name: String
    let isUnique: Bool
    let isPrimary: Bool
    var columns: [String]
  }

  private struct ForeignKeyAccumulator {
    let name: String
    let referencedTable: String
    var columns: [String]
    var referencedColumns: [String]
  }

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
      if profile.effectiveAccessLevel == .readOnly {
        _ = try await connection.query("PRAGMA query_only = ON")
      }
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

  func loadSchemaObjectDetails(profileID: UUID, object: SchemaObject) async throws
    -> SchemaObjectDetails
  {
    guard let connection = sessions[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    let objectBind = [SQLiteData.text(object.name)]
    let columnRows = try await connection.query(
      """
      SELECT
        cid,
        name,
        type,
        "notnull" AS is_not_null,
        dflt_value,
        pk
      FROM pragma_table_xinfo(?)
      ORDER BY cid
      """,
      objectBind
    )
    var primaryKeyColumns: [(position: Int, name: String)] = []
    let columns = columnRows.compactMap { row -> SchemaColumn? in
      guard let ordinal = row.column("cid")?.integer,
        let name = row.column("name")?.string,
        let notNull = row.column("is_not_null")?.integer,
        let primaryPosition = row.column("pk")?.integer
      else { return nil }
      if primaryPosition > 0 {
        primaryKeyColumns.append((primaryPosition, name))
      }
      return SchemaColumn(
        ordinalPosition: ordinal + 1,
        name: name,
        dataType: row.column("type")?.string ?? "",
        isNullable: notNull == 0 && primaryPosition == 0,
        defaultValue: row.column("dflt_value")?.string,
        characterSet: nil,
        collation: nil,
        comment: nil,
        isPrimaryKey: primaryPosition > 0
      )
    }

    let indexRows = try await connection.query(
      """
      SELECT
        index_list.name AS index_name,
        index_list."unique" AS is_unique,
        index_list.origin AS index_origin,
        index_info.name AS column_name
      FROM pragma_index_list(?) AS index_list
      LEFT JOIN pragma_index_info(index_list.name) AS index_info ON TRUE
      ORDER BY index_list.seq, index_info.seqno
      """,
      objectBind
    )
    var indexOrder: [String] = []
    var indexAccumulators: [String: IndexAccumulator] = [:]
    for row in indexRows {
      guard let name = row.column("index_name")?.string else { continue }
      if indexAccumulators[name] == nil {
        indexOrder.append(name)
        indexAccumulators[name] = IndexAccumulator(
          name: name,
          isUnique: row.column("is_unique")?.integer == 1,
          isPrimary: row.column("index_origin")?.string == "pk",
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
        method: "B-tree"
      )
    }

    var constraints: [SchemaConstraint] = []
    if !primaryKeyColumns.isEmpty {
      constraints.append(
        SchemaConstraint(
          name: "PRIMARY",
          kind: .primaryKey,
          columns: primaryKeyColumns.sorted { $0.position < $1.position }.map(\.name),
          referencedSchema: nil,
          referencedTable: nil,
          referencedColumns: [],
          definition: nil
        ))
    }

    let foreignKeyRows = try await connection.query(
      """
      SELECT id, seq, "table" AS referenced_table, "from" AS column_name,
        "to" AS referenced_column
      FROM pragma_foreign_key_list(?)
      ORDER BY id, seq
      """,
      objectBind
    )
    var foreignKeyOrder: [String] = []
    var foreignKeys: [String: ForeignKeyAccumulator] = [:]
    for row in foreignKeyRows {
      guard let identifier = row.column("id")?.integer,
        let referencedTable = row.column("referenced_table")?.string
      else { continue }
      let name = "fk_\(object.name)_\(identifier)"
      if foreignKeys[name] == nil {
        foreignKeyOrder.append(name)
        foreignKeys[name] = ForeignKeyAccumulator(
          name: name,
          referencedTable: referencedTable,
          columns: [],
          referencedColumns: []
        )
      }
      if let column = row.column("column_name")?.string {
        foreignKeys[name]?.columns.append(column)
      }
      if let referencedColumn = row.column("referenced_column")?.string {
        foreignKeys[name]?.referencedColumns.append(referencedColumn)
      }
    }
    constraints.append(
      contentsOf: foreignKeyOrder.compactMap { name -> SchemaConstraint? in
        guard let foreignKey = foreignKeys[name] else { return nil }
        return SchemaConstraint(
          name: foreignKey.name,
          kind: .foreignKey,
          columns: foreignKey.columns,
          referencedSchema: "main",
          referencedTable: foreignKey.referencedTable,
          referencedColumns: foreignKey.referencedColumns,
          definition: nil
        )
      })

    let definitionRows = try await connection.query(
      "SELECT sql FROM sqlite_schema WHERE name = ? AND type IN ('table', 'view')",
      objectBind
    )
    return SchemaObjectDetails(
      object: object,
      columns: columns,
      indexes: indexes,
      constraints: constraints,
      definition: definitionRows.first?.column("sql")?.string
    )
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
