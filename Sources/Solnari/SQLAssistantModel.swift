import Foundation
import SwiftUI

protocol CodexAssistantService: Actor {
  func start(handler: @escaping CodexAppServer.EventHandler) async throws
  func account() async throws -> Bool
  func login(deviceCode: Bool) async throws -> CodexJSON
  func cancelLogin(_ id: String) async
  func send(_ prompt: String) async throws -> AsyncThrowingStream<String, any Error>
  func cancelTurn() async
  func stop() async
}
extension CodexAppServer: CodexAssistantService {}

enum AssistantContextPolicy {
  static func validate(_ text: String, forbiddenValues: [String] = []) throws {
    guard text.utf8.count <= 100_000 else { throw CodexAssistantError.sensitiveContext }
    for value in forbiddenValues where !value.isEmpty {
      if text.localizedCaseInsensitiveContains(value) { throw CodexAssistantError.sensitiveContext }
    }
    let patterns = [
      #"(?i)(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|https?)://[^\s]+"#,
      #"(?i)\b(?:password|passwd|secret|token|api[_-]?key|authorization|private[_-]?key)\b\s*[=:]\s*\S+"#,
      #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, #"\b(?:sk-|ghp_|gho_|AIza)[A-Za-z0-9_-]{12,}"#,
      #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
      #"(?i)\b(?:[a-z0-9-]+\.)+(?:internal|local|lan|private)\b"#,
      #"\b(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)\b"#,
    ]
    if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
      throw CodexAssistantError.sensitiveContext
    }
  }
  static func rows(_ table: QueryTableData, optedIn: Bool) throws -> CodexJSON? {
    guard optedIn else { return nil }
    guard table.columns.count <= 30 else { throw CodexAssistantError.sensitiveContext }
    let sensitive =
      #"(?i)(password|passwd|secret|token|api.?key|credential|private.?key|authorization)"#
    guard
      !table.columns.contains(where: { $0.range(of: sensitive, options: .regularExpression) != nil }
      )
    else {
      throw CodexAssistantError.sensitiveContext
    }
    return .object([
      "columns": .array(table.columns.map(CodexJSON.string)),
      "rows": .array(table.rows.prefix(10).map { .array($0.map { .string($0.canonicalValue) }) }),
    ])
  }
}

struct AssistantSuggestion: Identifiable, Decodable, Sendable {
  var id: UUID { identifier }
  private let identifier = UUID()
  let explanation: String
  let sql: String?
  enum CodingKeys: CodingKey { case explanation, sql }
}

@MainActor
final class SQLAssistantModel: ObservableObject {
  @Published var draft = ""
  @Published private(set) var messages: [AssistantMessage] = []
  @Published private(set) var status = "Connect to Codex"
  @Published private(set) var isBusy = false
  @Published private(set) var signedIn = false
  @Published var includeSQL = false
  @Published var includeRows = false
  @Published var selectedObjects: Set<String> = []
  @Published private(set) var streamedText = ""
  @Published private(set) var loginURL: URL?
  @Published private(set) var deviceCode: String?
  private var loginID: String?
  private let service: any CodexAssistantService
  private var task: Task<Void, Never>?
  private var generation = UUID()

  init(service: any CodexAssistantService = CodexAppServer()) { self.service = service }

  func connect() {
    guard !isBusy else { return }
    isBusy = true
    messages = []
    streamedText = ""
    status = "Connecting to Codex…"
    let epoch = generation
    task = Task {
      do {
        try await service.start { [weak self] method, params in
          await self?.handle(method, params: params, epoch: epoch)
        }
        if epoch == generation { status = "Checking Codex account…" }
        let authenticated = try await service.account()
        guard epoch == generation else { return }
        signedIn = authenticated
        status =
          authenticated ? "Temporary conversation" : "Sign in to ChatGPT to use the SQL assistant."
      } catch { if epoch == generation { status = safeMessage(error) } }
      if epoch == generation { isBusy = false }
    }
  }

  func login(device: Bool) {
    guard !isBusy else { return }
    isBusy = true
    let epoch = generation
    task = Task {
      do {
        try await service.start { [weak self] method, params in
          await self?.handle(method, params: params, epoch: epoch)
        }
        if let loginID { await service.cancelLogin(loginID) }
        let response = try await service.login(deviceCode: device)
        guard epoch == generation else { return }
        guard let value = (response["authUrl"] ?? response["verificationUrl"])?.string,
          let url = URL(string: value), url.scheme == "https",
          ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(url.host ?? ""),
          let id = response["loginId"]?.string
        else { throw CodexAssistantError.invalidResponse }
        loginID = id
        loginURL = url
        deviceCode = response["userCode"]?.string
        status = "Complete sign-in in your browser, then check the connection."
      } catch { if epoch == generation { status = safeMessage(error) } }
      if epoch == generation { isBusy = false }
    }
  }

  func send(workspace: WorkspaceModel) {
    let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard signedIn, !isBusy, !question.isEmpty else { return }
    let profile = workspace.selectedConnection
    let originalSQL =
      includeSQL && workspace.selectedTab?.kind == .query ? workspace.selectedTab?.sql : nil
    let objects = workspace.schemaObjects.filter { selectedObjects.contains($0.id) }
    let rowOptIn = includeRows
    includeRows = false
    let table = workspace.queryTable
    let forbidden = workspace.connections.flatMap {
      [$0.host, $0.ssh?.host ?? "", $0.cloudSQL?.connectionName ?? ""]
    }
    .filter { !$0.isEmpty }
    let epoch = generation
    isBusy = true
    status = "Preparing selected context…"
    task = Task {
      do {
        try AssistantContextPolicy.validate(question, forbiddenValues: forbidden)
        var payload: [String: CodexJSON] = ["request": .string(question)]
        if let profile { payload["dialect"] = .string(profile.engine.rawValue) }
        if let originalSQL { payload["sql"] = .string(originalSQL) }
        guard objects.count <= 8 else { throw CodexAssistantError.sensitiveContext }
        var schema: [CodexJSON] = []
        for object in objects {
          guard let profile else { throw SolnariDatabaseError.missingConnection }
          let details = try await workspace.loadSchemaObjectDetails(object, profileID: profile.id)
          schema.append(
            .object([
              "schema": .string(object.schema), "name": .string(object.name),
              "kind": .string(object.kind.rawValue),
              "columns": .array(
                details.columns.map {
                  .object(["name": .string($0.name), "type": .string($0.dataType)])
                }),
            ]))
        }
        if !schema.isEmpty { payload["selectedSchema"] = .array(schema) }
        if let rows = try AssistantContextPolicy.rows(table, optedIn: rowOptIn) {
          payload["resultSample"] = rows
        }
        let prompt = String(
          decoding: try JSONEncoder().encode(CodexJSON.object(payload)), as: UTF8.self)
        try AssistantContextPolicy.validate(prompt, forbiddenValues: forbidden)
        try Task.checkCancellation()
        guard epoch == generation else { return }
        let events = try await service.send(prompt)
        messages.append(AssistantMessage(role: .user, text: question, sql: nil))
        draft = ""
        status = "Receiving response…"
        var final = ""
        for try await value in events {
          try Task.checkCancellation()
          guard epoch == generation else { return }
          final = value
          streamedText = Self.partialExplanation(value)
        }
        guard epoch == generation else { return }
        guard
          let response = try? JSONDecoder().decode(AssistantSuggestion.self, from: Data(final.utf8))
        else {
          throw CodexAssistantError.invalidResponse
        }
        messages.append(
          AssistantMessage(role: .assistant, text: response.explanation, sql: response.sql))
        status = "Temporary conversation"
      } catch {
        if epoch == generation {
          status = Task.isCancelled ? "Cancelled" : safeMessage(error)
          await service.stop()
          messages = []
          signedIn = false
        }
      }
      if epoch == generation {
        isBusy = false
        streamedText = ""
      }
    }
  }

  func close() {
    generation = UUID()
    task?.cancel()
    task = nil
    messages = []
    draft = ""
    streamedText = ""
    signedIn = false
    isBusy = true
    includeSQL = false
    includeRows = false
    selectedObjects = []
    loginURL = nil
    deviceCode = nil
    loginID = nil
    status = "Connect to Codex"
    let epoch = generation
    task = Task {
      await service.stop()
      if epoch == generation { isBusy = false }
    }
  }

  func cancel() {
    task?.cancel()
    let epoch = generation
    task = Task {
      await service.cancelTurn()
      if epoch == generation {
        isBusy = false
        signedIn = false
        messages = []
        streamedText = ""
        status = "Cancelled"
      }
    }
  }

  func shutdown() async {
    close()
    await task?.value
  }

  private func handle(_ method: String, params: CodexJSON, epoch: UUID) async {
    guard epoch == generation else { return }
    if method == "account/login/completed" {
      guard params["loginId"]?.string == loginID else { return }
      loginURL = nil
      deviceCode = nil
      loginID = nil
      signedIn = params["success"] == .bool(true)
      status = signedIn ? "Temporary conversation" : "Sign in to ChatGPT to use the SQL assistant."
    } else if method == "connection/closed" {
      signedIn = false
      status = CodexAssistantError.terminated.localizedDescription
    }
  }

  private func safeMessage(_ error: any Error) -> String {
    (error as? CodexAssistantError)?.localizedDescription
      ?? CodexAssistantError.requestFailed.localizedDescription
  }

  static func partialExplanation(_ json: String) -> String {
    if let decoded = try? JSONDecoder().decode(AssistantSuggestion.self, from: Data(json.utf8)) {
      return decoded.explanation
    }
    guard let start = json.range(of: #""explanation"\s*:\s*""#, options: .regularExpression) else {
      return ""
    }
    var text = ""
    var escaped = false
    for character in json[start.upperBound...] {
      if character == "\"" && !escaped { break }
      text.append(character)
      if character == "\\" { escaped.toggle() } else { escaped = false }
    }
    if escaped { text.removeLast() }
    return (try? JSONDecoder().decode(String.self, from: Data(("\"" + text + "\"").utf8))) ?? ""
  }
}
