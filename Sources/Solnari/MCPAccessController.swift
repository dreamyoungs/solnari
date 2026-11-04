import Foundation

enum MCPAccessState: Equatable {
  case disabled
  case starting
  case ready
  case suspended
  case failed(String)
}

enum MCPAccessError: LocalizedError {
  case noSelectedConnection
  case connectionNotReady
  case readOnlyConnectionRequired
  case readWriteConnectionRequired
  case selectedConnectionChanged
  case schemaObjectNotFound
  case responseTooLarge
  case sessionLimitReached

  var errorDescription: String? {
    switch self {
    case .noSelectedConnection:
      "Select a connection in Solnari before using its MCP tools."
    case .connectionNotReady:
      "The requested Solnari connection must already be connected. Refresh solnari_list_connections."
    case .readOnlyConnectionRequired:
      "MCP query execution is available only for a read-only Solnari connection."
    case .readWriteConnectionRequired:
      "Enable Read / Write on this connection in Solnari and reconnect before executing this MCP query."
    case .selectedConnectionChanged:
      "The database session has changed. Refresh solnari_list_connections before executing SQL."
    case .schemaObjectNotFound:
      "The requested schema object is not available in the requested connection."
    case .responseTooLarge:
      "The MCP response is too large. Select fewer columns or use a smaller LIMIT."
    case .sessionLimitReached:
      "All MCP sessions for this connection are in use. Try again after an active request completes."
    }
  }
}

struct MCPConnectionSnapshot: Codable, Sendable {
  let connectionID: UUID
  let name: String
  let database: String
  let engine: String
  let transport: String
  let accessLevel: String
  let status: String
  let serverVersion: String?
  let serverEncoding: String?
  let serverTimeZone: String?
  let mcpMaxConcurrentQueries: Int
  var executionTool: String? = nil
}

struct MCPQueryCell: Codable, Sendable {
  let kind: String
  let value: String?
  let truncated: Bool

  init(_ cell: QueryCellValue) {
    let rawValue: String?
    switch cell {
    case .integer(let value):
      kind = "integer"
      rawValue = String(value)
    case .decimal(let value):
      kind = "decimal"
      rawValue = value
    case .boolean(let value):
      kind = "boolean"
      rawValue = value ? "true" : "false"
    case .text(let value):
      kind = "text"
      rawValue = value
    case .instant:
      kind = "instant"
      rawValue = cell.canonicalValue
    case .localTimestamp:
      kind = "localTimestamp"
      rawValue = cell.canonicalValue
    case .date:
      kind = "date"
      rawValue = cell.canonicalValue
    case .binary(let byteCount):
      kind = "binary"
      rawValue = "<\(byteCount) bytes>"
    case .null:
      kind = "null"
      rawValue = nil
    }

    let maximumBytes = 16_384
    if let rawValue, rawValue.utf8.count > maximumBytes {
      let bytes = rawValue.utf8
      var end = bytes.index(bytes.startIndex, offsetBy: maximumBytes)
      while end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 {
        end = bytes.index(before: end)
      }
      value = String(decoding: bytes[..<end], as: UTF8.self)
      truncated = true
    } else {
      value = rawValue
      truncated = false
    }
  }
}

struct MCPQuerySnapshot: Codable, Sendable {
  let columns: [String]
  let rows: [[MCPQueryCell]]
  let returnedRowCount: Int
  let truncated: Bool
  let durationMilliseconds: Int
  var report: QueryExecutionReport? = nil
}

@MainActor
final class MCPAccessController: ObservableObject {
  private static let enabledKey = "solnari.mcpAccessEnabled"
  private static let maximumResultBytes = 2_000_000

  @Published private(set) var isEnabled: Bool
  @Published private(set) var state: MCPAccessState = .disabled

  private let workspace: WorkspaceModel
  private let defaults: UserDefaults
  private var bridge: LocalMCPBridge?

  init(
    workspace: WorkspaceModel,
    defaults: UserDefaults = .standard
  ) {
    self.workspace = workspace
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.enabledKey)
  }

  func activateIfNeeded() {
    guard isEnabled else {
      try? FileManager.default.removeItem(at: LocalMCPBridge.defaultSocketURL)
      state = .disabled
      return
    }
    start()
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    enabled ? start() : stop(state: .disabled)
  }

  func suspend() {
    guard isEnabled else { return }
    stop(state: .suspended)
  }

  func resumeIfNeeded() {
    guard isEnabled else { return }
    start()
  }

  func stopForTermination() {
    stop(state: isEnabled ? .suspended : .disabled)
  }

  var registrationArguments: [String]? {
    guard
      let node = Bundle.main.url(
        forResource: "node",
        withExtension: nil,
        subdirectory: "Node/bin"
      ),
      let guardScript = Bundle.main.url(
        forResource: "subprocess-guard",
        withExtension: "cjs",
        subdirectory: "NodeBackend"
      ),
      let server = Bundle.main.url(
        forResource: "mcp-server",
        withExtension: "cjs",
        subdirectory: "NodeBackend"
      )
    else { return nil }

    return [node.path, "--require", guardScript.path, server.path]
  }

  var registrationCommand: String? {
    registrationArguments.map {
      "codex mcp add solnari -- " + $0.map(Self.shellQuote).joined(separator: " ")
    }
  }

  func installInCodex() async throws {
    guard let executable = MCPRegistration.executableURL(), let arguments = registrationArguments
    else {
      throw MCPRegistration.RegistrationError.failed
    }
    try await MCPRegistration.install(executable: executable, serverArguments: arguments)
  }

  private func start() {
    stop(state: .starting)
    do {
      let bridge = try LocalMCPBridge { [weak self] request in
        guard let self else {
          return MCPBridgeResponse.failure(
            id: request.id,
            message: "Solnari is no longer available."
          )
        }
        return await self.handle(request)
      }
      self.bridge = bridge
      bridge.start()
      state = .ready
    } catch {
      bridge = nil
      state = .failed("The local MCP bridge could not start.")
    }
  }

  private func stop(state: MCPAccessState) {
    bridge?.stop()
    bridge = nil
    self.state = state
  }

  private func handle(_ request: MCPBridgeRequest) async -> MCPBridgeResponse {
    guard isEnabled, state == .ready else {
      return .failure(id: request.id, message: "Local MCP access is disabled or suspended.")
    }
    do {
      let result: String
      switch request.method {
      case "status":
        result = try encode(
          MCPStatusSnapshot(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
              ?? "development"))
      case "connections":
        result = try encode(workspace.mcpConnectedProfiles().map(connectionSnapshot))
      case "activeConnection":
        result = try encode(connectionSnapshot(from: try workspace.mcpSelectedProfile()))
      case "schema":
        let params = try decode(ConnectionParameters.self, from: request.paramsJSON)
        result = try encode(
          try await workspace.mcpSchemaSnapshot(connectionID: params.connectionID))
      case "describeObject":
        let params = try decode(DescribeObjectParameters.self, from: request.paramsJSON)
        result = try encode(
          try await workspace.mcpDescribeObject(
            connectionID: params.connectionID, schema: params.schema,
            name: params.name,
            kind: params.kind.flatMap(SchemaObjectKind.init(rawValue:))
          )
        )
      case "executeQuery":
        let params = try decode(ExecuteQueryParameters.self, from: request.paramsJSON)
        let snapshot = try await workspace.mcpExecuteQuery(
          connectionID: params.connectionID, sql: params.sql,
          maximumRows: min(max(params.maxRows ?? 50, 1), 200)
        )
        result = try Self.encodeExecutedQuery(snapshot)
      case "executeReadQuery":
        let params = try decode(ExecuteReadQueryParameters.self, from: request.paramsJSON)
        let maximumRows = min(max(params.maxRows ?? 50, 1), 200)
        result = try encode(
          try await workspace.mcpExecuteReadOnlyQuery(
            connectionID: params.connectionID, sql: params.sql,
            maximumRows: maximumRows
          )
        )
      default:
        return .failure(id: request.id, message: "The MCP bridge method is not supported.")
      }

      guard result.utf8.count <= Self.maximumResultBytes else {
        throw MCPAccessError.responseTooLarge
      }
      return .success(id: request.id, resultJSON: result)
    } catch let error as MCPAccessError {
      return .failure(
        id: request.id, message: error.localizedDescription,
        details: failureDetails(code: Self.errorCode(error), request: request))
    } catch let error as SolnariDatabaseError {
      return .failure(
        id: request.id, message: error.localizedDescription,
        details: failureDetails(code: "DATABASE_REQUEST_REJECTED", request: request))
    } catch {
      return .failure(id: request.id, message: "Solnari could not complete the MCP request.")
    }
  }

  private func connectionSnapshot(from profile: ConnectionProfile) -> MCPConnectionSnapshot {
    MCPConnectionSnapshot(
      connectionID: workspace.mcpConnectionID(for: profile),
      name: profile.name,
      database: profile.database,
      engine: profile.engine.rawValue,
      transport: profile.transport.rawValue,
      accessLevel: profile.effectiveAccessLevel.rawValue,
      status: profile.status.rawValue,
      serverVersion: profile.serverVersion,
      serverEncoding: profile.serverEncoding,
      serverTimeZone: profile.serverTimeZone,
      mcpMaxConcurrentQueries: profile.effectiveMCPMaxConcurrentQueries,
      executionTool: Self.executionTool(for: profile.effectiveAccessLevel)
    )
  }

  static func executionTool(for access: DatabaseAccessLevel?) -> String? {
    switch access {
    case .readOnly: "solnari_execute_read_query"
    case .readWrite: "solnari_execute_query"
    default: nil
    }
  }

  private static func errorCode(_ error: MCPAccessError) -> String {
    switch error {
    case .readOnlyConnectionRequired, .readWriteConnectionRequired: "MCP_ACCESS_LEVEL_MISMATCH"
    case .selectedConnectionChanged: "MCP_CONNECTION_CHANGED"
    case .sessionLimitReached: "MCP_SESSION_LIMIT_REACHED"
    case .noSelectedConnection, .connectionNotReady: "MCP_CONNECTION_NOT_READY"
    case .schemaObjectNotFound: "MCP_OBJECT_NOT_FOUND"
    case .responseTooLarge: "MCP_RESPONSE_TOO_LARGE"
    }
  }

  private func failureDetails(code: String, request: MCPBridgeRequest) -> MCPFailureDetails {
    let target = try? decode(ConnectionParameters.self, from: request.paramsJSON)
    let access = workspace.mcpConnectedProfiles().first {
      workspace.mcpConnectionID(for: $0) == target?.connectionID
    }?.effectiveAccessLevel
    let tool = Self.executionTool(for: access) ?? "No execution tool is available"
    return MCPFailureDetails(
      code: code, accessLevel: access?.rawValue ?? "No connection",
      requestedOperation: request.method,
      nextStep:
        "Refresh solnari_list_connections and use the intended connectionID without switching the app selection. \(tool). Only if the user chooses manual execution, select that database in a Solnari query tab and review the SQL there. Access changes require reconnecting.",
      verification:
        "Use SELECT catalog queries through the permitted execution tool to check membership or privileges. Command success alone does not verify the resulting state."
    )
  }

  static func encodeExecutedQuery(_ snapshot: MCPQuerySnapshot) throws -> String {
    let encoder = JSONEncoder()
    let data = try encoder.encode(snapshot)
    if data.count <= maximumResultBytes { return String(decoding: data, as: UTF8.self) }
    // 이미 완료된 쓰기를 응답 크기 오류로 보고하면 클라이언트가 재실행할 수 있습니다.
    let summary = MCPQuerySnapshot(
      columns: [], rows: [], returnedRowCount: 0, truncated: true,
      durationMilliseconds: snapshot.durationMilliseconds, report: snapshot.report)
    return String(decoding: try encoder.encode(summary), as: UTF8.self)
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func decode<T: Decodable>(_ type: T.Type, from json: String?) throws -> T {
    try JSONDecoder().decode(T.self, from: Data((json ?? "{}").utf8))
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

private struct ConnectionParameters: Decodable {
  let connectionID: UUID
}

private struct DescribeObjectParameters: Decodable {
  let connectionID: UUID
  let schema: String
  let name: String
  let kind: String?
}

private struct ExecuteReadQueryParameters: Decodable {
  let connectionID: UUID
  let sql: String
  let maxRows: Int?
}

private struct ExecuteQueryParameters: Decodable {
  let connectionID: UUID
  let sql: String
  let maxRows: Int?
}

private struct MCPStatusSnapshot: Encodable {
  let appVersion: String
  let status = "ready"
  let supportsMultipleConnections = true
  let requiresUISelection = false
  let connectionsTool = "solnari_list_connections"
  let connectionScope =
    "Use multiple connected databases concurrently by specifying connectionID on each request. Do not ask to switch the app selection."
  let writePolicy =
    "Read / Write connections execute changes immediately. Read-only connections reject changes."
}
