import Foundation
import PostgresNIO

actor PostgreSQLBackend {
  private struct Session: Sendable {
    let client: PostgresClient
    let runTask: Task<Void, Never>
  }

  private var sessions: [UUID: Session] = [:]

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
    let definition: String?
    var columns: [String]
    var referencedColumns: [String]
  }

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

  func loadSchemaObjectDetails(profileID: UUID, object: SchemaObject) async throws
    -> SchemaObjectDetails
  {
    guard let client = sessions[profileID]?.client else {
      throw SolnariDatabaseError.notConnected
    }

    let columnQuery: PostgresQuery = """
      SELECT
        CAST(attribute.attnum AS bigint) AS ordinal_position,
        attribute.attname AS column_name,
        pg_catalog.format_type(attribute.atttypid, attribute.atttypmod) AS data_type,
        NOT attribute.attnotnull AS is_nullable,
        pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid) AS default_value,
        column_collation.collname AS collation_name,
        pg_catalog.col_description(relation.oid, attribute.attnum) AS column_comment,
        EXISTS (
          SELECT 1
          FROM pg_catalog.pg_constraint AS primary_constraint
          WHERE primary_constraint.conrelid = relation.oid
            AND primary_constraint.contype = 'p'
            AND attribute.attnum = ANY(primary_constraint.conkey)
        ) AS is_primary_key
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      JOIN pg_catalog.pg_attribute AS attribute ON attribute.attrelid = relation.oid
      LEFT JOIN pg_catalog.pg_attrdef AS default_value
        ON default_value.adrelid = relation.oid
        AND default_value.adnum = attribute.attnum
      LEFT JOIN pg_catalog.pg_collation AS column_collation
        ON column_collation.oid = attribute.attcollation
      WHERE namespace.nspname = \(object.schema)
        AND relation.relname = \(object.name)
        AND attribute.attnum > 0
        AND NOT attribute.attisdropped
      ORDER BY attribute.attnum;
      """
    let columnRows = try await metadataRows(
      using: client,
      query: columnQuery,
      stage: .columns
    )
    var columns: [SchemaColumn] = []
    for row in columnRows {
      let cells = Array(row)
      guard cells.count == 8 else { continue }
      columns.append(
        SchemaColumn(
          ordinalPosition: Int(clamping: try cells[0].decode(Int64.self)),
          name: try cells[1].decode(String.self),
          dataType: try cells[2].decode(String.self),
          isNullable: try cells[3].decode(Bool.self),
          defaultValue: try? cells[4].decode(String.self),
          characterSet: nil,
          collation: try? cells[5].decode(String.self),
          comment: try? cells[6].decode(String.self),
          isPrimaryKey: try cells[7].decode(Bool.self)
        ))
    }

    let indexQuery: PostgresQuery = """
      SELECT
        index_relation.relname AS index_name,
        index_record.indisunique AS is_unique,
        index_record.indisprimary AS is_primary,
        access_method.amname AS index_method,
        COALESCE(
          attribute.attname,
          pg_catalog.pg_get_indexdef(
            index_record.indexrelid,
            CAST(index_key.ordinal_position AS integer),
            TRUE
          )
        ) AS column_name
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      JOIN pg_catalog.pg_index AS index_record ON index_record.indrelid = relation.oid
      JOIN pg_catalog.pg_class AS index_relation ON index_relation.oid = index_record.indexrelid
      JOIN pg_catalog.pg_am AS access_method ON access_method.oid = index_relation.relam
      LEFT JOIN LATERAL unnest(index_record.indkey) WITH ORDINALITY
        AS index_key(attribute_number, ordinal_position) ON TRUE
      LEFT JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = relation.oid
        AND attribute.attnum = index_key.attribute_number
      WHERE namespace.nspname = \(object.schema)
        AND relation.relname = \(object.name)
      ORDER BY index_relation.relname, index_key.ordinal_position;
      """
    let indexRows = try await metadataRows(
      using: client,
      query: indexQuery,
      stage: .indexes
    )
    var indexOrder: [String] = []
    var indexAccumulators: [String: IndexAccumulator] = [:]
    for row in indexRows {
      let cells = Array(row)
      guard cells.count == 5 else { continue }
      let name = try cells[0].decode(String.self)
      if indexAccumulators[name] == nil {
        indexOrder.append(name)
        indexAccumulators[name] = IndexAccumulator(
          name: name,
          isUnique: try cells[1].decode(Bool.self),
          isPrimary: try cells[2].decode(Bool.self),
          method: try? cells[3].decode(String.self),
          columns: []
        )
      }
      if let column = try? cells[4].decode(String.self) {
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

    let constraintQuery: PostgresQuery = """
      SELECT
        constraint_record.conname AS constraint_name,
        CAST(constraint_record.contype AS text) AS constraint_type,
        attribute.attname AS column_name,
        referenced_namespace.nspname AS referenced_schema,
        referenced_relation.relname AS referenced_table,
        referenced_attribute.attname AS referenced_column,
        pg_catalog.pg_get_constraintdef(constraint_record.oid, TRUE) AS definition
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      JOIN pg_catalog.pg_constraint AS constraint_record
        ON constraint_record.conrelid = relation.oid
      LEFT JOIN LATERAL unnest(constraint_record.conkey) WITH ORDINALITY
        AS constraint_key(attribute_number, ordinal_position) ON TRUE
      LEFT JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = relation.oid
        AND attribute.attnum = constraint_key.attribute_number
      LEFT JOIN pg_catalog.pg_class AS referenced_relation
        ON referenced_relation.oid = constraint_record.confrelid
      LEFT JOIN pg_catalog.pg_namespace AS referenced_namespace
        ON referenced_namespace.oid = referenced_relation.relnamespace
      LEFT JOIN LATERAL unnest(constraint_record.confkey) WITH ORDINALITY
        AS referenced_key(attribute_number, ordinal_position)
        ON referenced_key.ordinal_position = constraint_key.ordinal_position
      LEFT JOIN pg_catalog.pg_attribute AS referenced_attribute
        ON referenced_attribute.attrelid = referenced_relation.oid
        AND referenced_attribute.attnum = referenced_key.attribute_number
      WHERE namespace.nspname = \(object.schema)
        AND relation.relname = \(object.name)
      ORDER BY constraint_record.conname, constraint_key.ordinal_position;
      """
    let constraintRows = try await metadataRows(
      using: client,
      query: constraintQuery,
      stage: .constraints
    )
    var constraintOrder: [String] = []
    var constraintAccumulators: [String: ConstraintAccumulator] = [:]
    for row in constraintRows {
      let cells = Array(row)
      guard cells.count == 7 else { continue }
      let name = try cells[0].decode(String.self)
      if constraintAccumulators[name] == nil {
        constraintOrder.append(name)
        constraintAccumulators[name] = ConstraintAccumulator(
          name: name,
          kind: Self.constraintKind(try cells[1].decode(String.self)),
          referencedSchema: try? cells[3].decode(String.self),
          referencedTable: try? cells[4].decode(String.self),
          definition: try? cells[6].decode(String.self),
          columns: [],
          referencedColumns: []
        )
      }
      if let column = try? cells[2].decode(String.self) {
        constraintAccumulators[name]?.columns.append(column)
      }
      if let referencedColumn = try? cells[5].decode(String.self) {
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
        definition: constraint.definition
      )
    }

    var definition: String?
    if object.kind == .view || object.kind == .materializedView {
      let definitionQuery: PostgresQuery = """
        SELECT pg_catalog.pg_get_viewdef(relation.oid, TRUE) AS definition
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = \(object.schema)
          AND relation.relname = \(object.name);
        """
      let definitionRows = try await metadataRows(
        using: client,
        query: definitionQuery,
        stage: .definition
      )
      if let row = definitionRows.first {
        definition = try? Array(row)[0].decode(String.self)
      }
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

  private func metadataRows(
    using client: PostgresClient,
    query: PostgresQuery,
    stage: SchemaMetadataStage
  ) async throws -> [PostgresRow] {
    do {
      return try await client.query(query).collect()
    } catch let error as PSQLError {
      let sqlState = error.serverInfo?[.sqlState]
      let reason: SchemaMetadataFailureReason
      switch sqlState {
      case "42501": reason = .permissionDenied
      case "42601", "42703", "42883", "0A000": reason = .incompatibleQuery
      case "57014": reason = .cancelled
      default: reason = .databaseRejected
      }
      throw SchemaMetadataError(stage: stage, reason: reason, sqlState: sqlState)
    } catch {
      throw SchemaMetadataError(stage: stage, reason: .databaseRejected, sqlState: nil)
    }
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

  private static func constraintKind(_ value: String) -> SchemaConstraintKind {
    switch value {
    case "p": .primaryKey
    case "f": .foreignKey
    case "u": .unique
    case "c": .check
    case "x": .exclusion
    default: .other
    }
  }

  private static func milliseconds(from duration: Duration) -> Int {
    let components = duration.components
    let seconds = components.seconds * 1_000
    let attoseconds = components.attoseconds / 1_000_000_000_000_000
    return Int(clamping: seconds + attoseconds)
  }
}
