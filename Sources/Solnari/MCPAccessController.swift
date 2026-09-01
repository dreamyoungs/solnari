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
  case schemaObjectNotFound
  case responseTooLarge
  case queryAlreadyRunning

  var errorDescription: String? {
    switch self {
    case .noSelectedConnection:
      "Select a connection in Solnari before using its MCP tools."
    case .connectionNotReady:
      "The selected Solnari connection must already be connected."
    case .readOnlyConnectionRequired:
      "MCP query execution is available only for a read-only Solnari connection."
    case .schemaObjectNotFound:
      "The requested schema object is not available in the selected connection."
    case .responseTooLarge:
      "The MCP response is too large. Select fewer columns or use a smaller LIMIT."
    case .queryAlreadyRunning:
      "Another query is already running in Solnari."
    }
  }
}

struct MCPConnectionSnapshot: Codable, Sendable {
  let name: String
  let database: String
  let engine: String
  let transport: String
  let accessLevel: String
  let status: String
  let serverVersion: String?
  let serverEncoding: String?
  let serverTimeZone: String?
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

  var registrationCommand: String? {
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

    return [
      "codex mcp add solnari --",
      Self.shellQuote(node.path),
      "--require",
      Self.shellQuote(guardScript.path),
      Self.shellQuote(server.path),
    ].joined(separator: " ")
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
    do {
      let result: String
      switch request.method {
      case "status":
        result = try encode(["status": "ready"])
      case "activeConnection":
        result = try encode(connectionSnapshot(from: try workspace.mcpSelectedProfile()))
      case "schema":
        result = try encode(try await workspace.mcpSchemaSnapshot())
      case "describeObject":
        let params = try decode(DescribeObjectParameters.self, from: request.paramsJSON)
        result = try encode(
          try await workspace.mcpDescribeObject(
            schema: params.schema,
            name: params.name,
            kind: params.kind.flatMap(SchemaObjectKind.init(rawValue:))
          )
        )
      case "executeReadQuery":
        let params = try decode(ExecuteReadQueryParameters.self, from: request.paramsJSON)
        let maximumRows = min(max(params.maxRows ?? 50, 1), 200)
        result = try encode(
          try await workspace.mcpExecuteReadOnlyQuery(
            sql: params.sql,
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
      return .failure(id: request.id, message: error.localizedDescription)
    } catch let error as SolnariDatabaseError {
      return .failure(id: request.id, message: error.localizedDescription)
    } catch {
      return .failure(id: request.id, message: "Solnari could not complete the MCP request.")
    }
  }

  private func connectionSnapshot(from profile: ConnectionProfile) -> MCPConnectionSnapshot {
    MCPConnectionSnapshot(
      name: profile.name,
      database: profile.database,
      engine: profile.engine.rawValue,
      transport: profile.transport.rawValue,
      accessLevel: profile.effectiveAccessLevel.rawValue,
      status: profile.status.rawValue,
      serverVersion: profile.serverVersion,
      serverEncoding: profile.serverEncoding,
      serverTimeZone: profile.serverTimeZone
    )
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

private struct DescribeObjectParameters: Decodable {
  let schema: String
  let name: String
  let kind: String?
}

private struct ExecuteReadQueryParameters: Decodable {
  let sql: String
  let maxRows: Int?
}
