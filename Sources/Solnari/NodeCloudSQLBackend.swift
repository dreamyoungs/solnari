import Foundation

actor NodeCloudSQLBackend {
  private struct ConnectionParameters: Codable, Sendable {
    let profileID: UUID
    let engine: DatabaseEngine
    let instanceConnectionName: String
    let user: String
    let database: String
    let password: String?
    let useIAM: Bool
    let ipType: String
    let readOnly: Bool
  }

  private struct ProfileParameters: Codable, Sendable {
    let profileID: UUID
  }

  private struct ObjectParameters: Codable, Sendable {
    let profileID: UUID
    let object: SchemaObject
  }

  private struct ExecuteParameters: Codable, Sendable {
    let profileID: UUID
    let sql: String
  }

  private struct EmptyParameters: Codable, Sendable {}

  private struct DisconnectResponse: Decodable, Sendable {
    let disconnected: Bool
  }

  private struct ExecutionResponse: Decodable, Sendable {
    struct Cell: Decodable, Sendable {
      let kind: String
      let value: String?
      let byteCount: Int?
    }

    let columns: [String]
    let rows: [[Cell]]
    let durationMilliseconds: Int
  }

  private let client: NodeBackendClient

  init(client: NodeBackendClient = .shared) {
    self.client = client
  }

  func testConnection(profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    try await client.call(
      method: "cloudSql.testConnection",
      params: try connectionParameters(profile: profile, password: password)
    )
  }

  func cancelTestConnection(profileID: UUID) async {
    let _: DisconnectResponse? = try? await client.call(
      method: "cloudSql.cancelTestConnection",
      params: ProfileParameters(profileID: profileID)
    )
  }

  func connect(profile: ConnectionProfile, password: String) async throws -> ConnectionMetadata {
    try await client.call(
      method: "database.connect",
      params: try connectionParameters(profile: profile, password: password)
    )
  }

  func disconnect(profileID: UUID) async {
    let _: DisconnectResponse? = try? await client.call(
      method: "database.disconnect",
      params: ProfileParameters(profileID: profileID)
    )
  }

  func disconnectAll() async {
    let _: DisconnectResponse? = try? await client.call(
      method: "database.disconnectAll",
      params: EmptyParameters()
    )
    await client.stop()
  }

  func loadSchema(profileID: UUID) async throws -> SchemaSnapshot {
    try await client.call(
      method: "database.schema",
      params: ProfileParameters(profileID: profileID)
    )
  }

  func loadSchemaObjectDetails(profileID: UUID, object: SchemaObject) async throws
    -> SchemaObjectDetails
  {
    try await client.call(
      method: "database.details",
      params: ObjectParameters(profileID: profileID, object: object)
    )
  }

  func execute(profileID: UUID, sql: String) async throws -> QueryExecutionResult {
    let response: ExecutionResponse = try await client.call(
      method: "database.execute",
      params: ExecuteParameters(profileID: profileID, sql: sql)
    )
    return QueryExecutionResult(
      table: QueryTableData(
        columns: response.columns,
        rows: response.rows.map { $0.map(Self.cellValue) }
      ),
      durationMilliseconds: response.durationMilliseconds
    )
  }

  private func connectionParameters(profile: ConnectionProfile, password: String) throws
    -> ConnectionParameters
  {
    guard let cloudSQL = profile.cloudSQL else { throw SolnariDatabaseError.incompleteConnection }
    return ConnectionParameters(
      profileID: profile.id,
      engine: profile.engine,
      instanceConnectionName: cloudSQL.connectionName,
      user: profile.username,
      database: profile.database,
      password: password.isEmpty ? nil : password,
      useIAM: cloudSQL.useIAMAuthentication,
      ipType: "PUBLIC",
      readOnly: profile.effectiveAccessLevel == .readOnly
    )
  }

  private static func cellValue(_ cell: ExecutionResponse.Cell) -> QueryCellValue {
    switch cell.kind {
    case "integer":
      Int64(cell.value ?? "").map(QueryCellValue.integer) ?? .decimal(cell.value ?? "0")
    case "decimal": .decimal(cell.value ?? "")
    case "boolean": .boolean(cell.value == "true")
    case "instant":
      instantDate(from: cell.value ?? "").map(QueryCellValue.instant)
        ?? .text(cell.value ?? "")
    case "localTimestamp":
      localDate(
        from: cell.value ?? "", formats: ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"]
      )
      .map(QueryCellValue.localTimestamp) ?? .text(cell.value ?? "")
    case "date":
      localDate(from: cell.value ?? "", formats: ["yyyy-MM-dd"])
        .map(QueryCellValue.date) ?? .text(cell.value ?? "")
    case "binary": .binary(byteCount: cell.byteCount ?? 0)
    case "null": .null
    default: .text(cell.value ?? "")
    }
  }

  private static func instantDate(from value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func localDate(from value: String, formats: [String]) -> Date? {
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .iso8601)
      formatter.timeZone = .gmt
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    return nil
  }
}
