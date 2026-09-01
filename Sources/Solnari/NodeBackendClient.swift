import Foundation

enum NodeBackendError: LocalizedError, Sendable {
  case executableUnavailable
  case bundleUnavailable
  case processTerminated
  case invalidResponse
  case backend(code: String, message: String)

  var errorDescription: String? {
    switch self {
    case .executableUnavailable:
      String(localized: "The bundled Node runtime is unavailable.")
    case .bundleUnavailable:
      String(localized: "The Solnari Node backend bundle is unavailable.")
    case .processTerminated:
      String(localized: "The Solnari Node backend stopped unexpectedly.")
    case .invalidResponse:
      String(localized: "The Solnari Node backend returned an invalid response.")
    case .backend(let code, let message):
      "\(Self.localizedBackendMessage(code: code, fallback: message)) · \(code)"
    }
  }

  private static func localizedBackendMessage(code: String, fallback: String) -> String {
    if code.hasPrefix("CLOUD_SQL_CONNECTION_") {
      if code.contains("SQLSTATE_28") || code.contains("ER_ACCESS_DENIED_ERROR")
        || code.hasSuffix("HTTP_401") || code.hasSuffix("HTTP_403")
      {
        return String(localized: "Cloud SQL or database authentication was rejected.")
      }
      if code.contains("SQLSTATE_3D000") || code.contains("ER_BAD_DB_ERROR") {
        return String(localized: "The selected database does not exist or is unavailable.")
      }
      return String(localized: "Cloud SQL secure connection failed.")
    }
    if code.hasPrefix("SCHEMA_") {
      if code.contains("SQLSTATE_42501") || code.contains("ER_DBACCESS_DENIED_ERROR")
        || code.contains("ER_TABLEACCESS_DENIED_ERROR")
      {
        return String(localized: "The database account cannot read this schema metadata.")
      }
      if code.contains("SQLSTATE_42601") || code.contains("SQLSTATE_42703")
        || code.contains("SQLSTATE_42883") || code.contains("SQLSTATE_0A000")
      {
        return String(
          localized: "Solnari's metadata query is not compatible with this PostgreSQL server.")
      }
      if code.contains("SQLSTATE_57014") {
        return String(localized: "The schema metadata query was cancelled.")
      }
      return String(localized: "The database rejected the schema metadata query.")
    }
    if code == "DATABASE_NOT_CONNECTED" {
      return String(localized: "Connect to the database before running a query.")
    }
    if code == "QUERY_RESULT_TOO_LARGE" {
      return String(localized: "The query result is too large to display safely.")
    }
    if code == "QUERY_CELL_TOO_LARGE" {
      return String(localized: "A query result cell is too large to display safely.")
    }
    if code.hasPrefix("QUERY_") {
      if code.contains("SQLSTATE_42601") || code.contains("ER_PARSE_ERROR")
        || code.contains("ER_SYNTAX_ERROR")
      {
        return String(localized: "The database reported a SQL syntax error.")
      }
      if code.contains("SQLSTATE_42501") || code.contains("ER_DBACCESS_DENIED_ERROR")
        || code.contains("ER_TABLEACCESS_DENIED_ERROR")
      {
        return String(localized: "The database account is not allowed to run this query.")
      }
      if code.contains("SQLSTATE_57014") {
        return String(localized: "The database cancelled the query.")
      }
      if code.contains("SQLSTATE_42P01") || code.contains("SQLSTATE_42703")
        || code.contains("ER_NO_SUCH_TABLE") || code.contains("ER_BAD_FIELD_ERROR")
      {
        return String(localized: "The query references a table or column that does not exist.")
      }
      return String(localized: "The database rejected the query.")
    }
    return fallback
  }
}

actor NodeBackendClient {
  static let shared = NodeBackendClient()

  private struct Request<Parameters: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Parameters
  }

  private struct ResponseIdentifier: Decodable {
    let id: Int?
  }

  private struct SuccessResponse<Result: Decodable>: Decodable {
    let result: Result
  }

  private struct FailureResponse: Decodable {
    struct Failure: Decodable {
      struct Details: Decodable {
        let diagnosticCode: String?
      }

      let message: String
      let data: Details?
    }

    let error: Failure?
  }

  private var process: Process?
  private var inputHandle: FileHandle?
  private var readerTask: Task<Void, Never>?
  private var nextRequestID = 1
  private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]

  deinit {
    readerTask?.cancel()
    if process?.isRunning == true {
      process?.terminate()
    }
  }

  func call<Parameters: Encodable & Sendable, Result: Decodable & Sendable>(
    method: String,
    params: Parameters,
    as resultType: Result.Type = Result.self
  ) async throws -> Result {
    try startIfNeeded()
    let requestID = nextRequestID
    nextRequestID += 1
    var requestData = try JSONEncoder().encode(
      Request(id: requestID, method: method, params: params)
    )
    guard requestData.count <= 1_048_576 else { throw NodeBackendError.invalidResponse }
    requestData.append(0x0A)

    let responseData: Data = try await withCheckedThrowingContinuation { continuation in
      pending[requestID] = continuation
      do {
        try inputHandle?.write(contentsOf: requestData)
      } catch {
        pending.removeValue(forKey: requestID)
        continuation.resume(throwing: NodeBackendError.processTerminated)
      }
    }
    if let failure = try? JSONDecoder().decode(FailureResponse.self, from: responseData),
      let backendError = failure.error
    {
      throw NodeBackendError.backend(
        code: backendError.data?.diagnosticCode ?? "NODE_BACKEND_ERROR",
        message: backendError.message
      )
    }
    guard
      let response = try? JSONDecoder().decode(SuccessResponse<Result>.self, from: responseData)
    else {
      throw NodeBackendError.invalidResponse
    }
    return response.result
  }

  func stop() {
    readerTask?.cancel()
    readerTask = nil
    inputHandle?.closeFile()
    inputHandle = nil
    if process?.isRunning == true {
      process?.terminate()
    }
    process = nil
    failPendingRequests()
  }

  private func startIfNeeded() throws {
    if process?.isRunning == true { return }
    let executable = try Self.nodeExecutableURL()
    let backend = try Self.backendBundleURL()
    let subprocessGuard = try Self.subprocessGuardURL()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--require", subprocessGuard.path, backend.path]
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice
    process.currentDirectoryURL = try Self.runtimeDirectoryURL()
    process.environment = Self.sanitizedEnvironment()
    try process.run()

    self.process = process
    inputHandle = standardInput.fileHandleForWriting
    let outputHandle = standardOutput.fileHandleForReading
    readerTask = Task.detached { [weak self] in
      do {
        for try await line in outputHandle.bytes.lines {
          guard line.utf8.count <= 8_388_608 else { continue }
          await self?.receive(Data(line.utf8))
        }
      } catch {
        // EOF and read failures are handled as a terminated backend.
      }
      await self?.backendDidTerminate()
    }
  }

  private func receive(_ data: Data) {
    guard let identifier = try? JSONDecoder().decode(ResponseIdentifier.self, from: data),
      let requestID = identifier.id,
      let continuation = pending.removeValue(forKey: requestID)
    else { return }
    continuation.resume(returning: data)
  }

  private func backendDidTerminate() {
    process = nil
    inputHandle = nil
    readerTask = nil
    failPendingRequests()
  }

  private func failPendingRequests() {
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: NodeBackendError.processTerminated)
    }
  }

  private static func nodeExecutableURL() throws -> URL {
    if let resourceURL = Bundle.main.resourceURL {
      let bundled = resourceURL.appendingPathComponent("Node/bin/node")
      if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    }
    if let configured = ProcessInfo.processInfo.environment["SOLNARI_NODE"],
      FileManager.default.isExecutableFile(atPath: configured)
    {
      return URL(fileURLWithPath: configured)
    }
    guard
      let resolved = try? ExecutableResolver.resolve(name: "node", environmentKey: "SOLNARI_NODE")
    else {
      throw NodeBackendError.executableUnavailable
    }
    return URL(fileURLWithPath: resolved)
  }

  private static func backendBundleURL() throws -> URL {
    if let resourceURL = Bundle.main.resourceURL {
      let bundled = resourceURL.appendingPathComponent("NodeBackend/server.cjs")
      if FileManager.default.isReadableFile(atPath: bundled.path) { return bundled }
    }
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("backend/dist/server.cjs")
    guard FileManager.default.isReadableFile(atPath: development.path) else {
      throw NodeBackendError.bundleUnavailable
    }
    return development
  }

  private static func subprocessGuardURL() throws -> URL {
    if let resourceURL = Bundle.main.resourceURL {
      let bundled = resourceURL.appendingPathComponent("NodeBackend/subprocess-guard.cjs")
      if FileManager.default.isReadableFile(atPath: bundled.path) { return bundled }
    }
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("backend/src/subprocess-guard.cjs")
    guard FileManager.default.isReadableFile(atPath: development.path) else {
      throw NodeBackendError.bundleUnavailable
    }
    return development
  }

  private static func runtimeDirectoryURL() throws -> URL {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let directory =
      applicationSupport
      .appendingPathComponent("Solnari", isDirectory: true)
      .appendingPathComponent("Runtime", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
    return directory
  }

  private static func sanitizedEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    for key in [
      "BASH_ENV", "ENV", "NODE_OPTIONS", "NODE_PATH", "SOLNARI_GCLOUD",
    ] {
      environment.removeValue(forKey: key)
    }
    if let credentialPath = environment["GOOGLE_APPLICATION_CREDENTIALS"],
      isUserProtectedPath(credentialPath)
    {
      environment.removeValue(forKey: "GOOGLE_APPLICATION_CREDENTIALS")
    }
    return environment
  }

  private static func isUserProtectedPath(_ path: String) -> Bool {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser
    return ["Documents", "Desktop", "Downloads"].contains { directory in
      let protectedDirectory = home.appendingPathComponent(directory, isDirectory: true).path
      return standardized == protectedDirectory || standardized.hasPrefix(protectedDirectory + "/")
    }
  }
}
