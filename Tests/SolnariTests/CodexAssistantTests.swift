import Foundation
import Testing

@testable import Solnari

struct CodexAssistantTests {
  private var validThread: CodexJSON {
    .object([
      "thread": .object(["id": .string("thread"), "ephemeral": .bool(true), "path": .null]),
      "sandbox": .object(["type": .string("readOnly"), "networkAccess": .bool(false)]),
      "approvalPolicy": .string("never"), "instructionSources": .array([]),
    ])
  }

  @Test("임시 여부·명시적 null 경로·제한된 실행 정책을 모두 검증한다")
  func ephemeralContract() throws {
    #expect(try CodexSessionPolicy.validateThread(validThread) == "thread")
    for thread in [
      CodexJSON.object(["id": .string("x"), "ephemeral": .bool(false), "path": .null]),
      .object(["id": .string("x"), "ephemeral": .bool(true)]),
      .object(["id": .string("x"), "ephemeral": .bool(true), "path": .string("/tmp/thread")]),
    ] {
      guard case .object(var response) = validThread else { return }
      response["thread"] = thread
      #expect(throws: CodexAssistantError.privacy) {
        try CodexSessionPolicy.validateThread(.object(response))
      }
    }
    guard case .object(var unsafe) = validThread else { return }
    unsafe["sandbox"] = .object(["type": .string("dangerFullAccess")])
    #expect(throws: CodexAssistantError.privacy) {
      try CodexSessionPolicy.validateThread(.object(unsafe))
    }
    #expect(CodexSessionPolicy.supports(version: "solnari_sql_assistant/0.153.4 (test)"))
    #expect(!CodexSessionPolicy.supports(version: "codex-cli 0.154.0"))
  }

  @Test("비밀·연결 주소·민감한 결과 컬럼을 차단하고 결과 행은 기본 제외한다")
  func contextFiltering() throws {
    for text in [
      "password=example", "postgresql://user:pass@host/db", "token: abc", "sk-abcdefghijklmnop",
      "eyJabc.def.ghi", "10.1.2.3", "db.internal", "-----BEGIN RSA PRIVATE KEY-----",
    ] {
      #expect(throws: CodexAssistantError.sensitiveContext) {
        try AssistantContextPolicy.validate(text)
      }
    }
    #expect(throws: CodexAssistantError.sensitiveContext) {
      try AssistantContextPolicy.validate("select 'secret-host'", forbiddenValues: ["secret-host"])
    }
    let table = QueryTableData(columns: ["password"], rows: [[.text("secret")]])
    #expect(try AssistantContextPolicy.rows(table, optedIn: false) == nil)
    #expect(throws: CodexAssistantError.sensitiveContext) {
      try AssistantContextPolicy.rows(table, optedIn: true)
    }
    let normal = QueryTableData(columns: ["id"], rows: (0..<20).map { [.integer(Int64($0))] })
    #expect(try AssistantContextPolicy.rows(normal, optedIn: true)?["rows"]?.array?.count == 10)
    try AssistantContextPolicy.validate("Explain SELECT id FROM items")
  }

  @Test(
    "실제 JSONL 프로세스에서 임시 검증·스트리밍·취소·오류·재접속을 검증한다",
    .enabled(if: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_FAKE"] != nil))
  func transportContract() async throws {
    let executable = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_FAKE"]!)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexTransport-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("synthetic-private-data".utf8).write(to: root.appendingPathComponent("blocked-secret"))
    defer { try? FileManager.default.removeItem(at: root) }
    for scenario in [
      "normal", "persistent", "path", "malformed", "tool", "failure", "hang", "exit",
    ] {
      let home = root.appendingPathComponent(scenario)
      let service = CodexAppServer(executable: executable, homeDirectory: home)
      if scenario == "exit" {
        let started = ContinuousClock.now
        await #expect(throws: CodexAssistantError.terminated) {
          try await service.start { _, _ in }
        }
        #expect(started.duration(to: .now) < .seconds(3))
        continue
      }
      try await service.start { _, _ in }
      #expect(try await service.account())
      if scenario == "persistent" || scenario == "path" {
        await #expect(throws: CodexAssistantError.privacy) {
          try await service.send("synthetic-only-context")
        }
        #expect(
          !FileManager.default.fileExists(atPath: home.appendingPathComponent("turn-count").path))
      } else {
        let stream = try await service.send("synthetic-only-context")
        if scenario == "hang" {
          await service.cancelTurn()
          #expect(
            FileManager.default.fileExists(
              atPath: home.appendingPathComponent("interrupt-count").path))
        }
        do {
          var final = ""
          for try await value in stream { final = value }
          #expect(scenario == "normal")
          let parsed = try JSONDecoder().decode(AssistantSuggestion.self, from: Data(final.utf8))
          #expect(parsed.sql == "SELECT 1")
        } catch {
          #expect(scenario != "normal")
          #expect(!error.localizedDescription.contains("secret diagnostic"))
        }
      }
      await service.stop()
      try await service.start { _, _ in }
      #expect(try await service.account())
      await service.stop()
      let files = try FileManager.default.contentsOfDirectory(
        at: home, includingPropertiesForKeys: nil)
      #expect(
        Set(files.map(\.lastPathComponent)).isSubset(of: [
          "workspace", "tmp", "turn-count", "interrupt-count",
        ]))
    }
  }

  @Test(
    "제한된 Codex 프로세스에서도 키체인 테스트 항목을 저장·조회·삭제한다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_KEYCHAIN"] == "1"
        && ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_FAKE"] != nil))
  func keychainPersistence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexKeychain-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let service = CodexAppServer(
      executable: URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_FAKE"]!),
      homeDirectory: root.appendingPathComponent("keychain"))
    do {
      try await service.start { _, _ in }
      #expect(try await service.account())
      await service.stop()
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test(
    "유휴 Node 백엔드가 Codex 파이프 읽기를 막지 않는다",
    .enabled(if: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_FAKE"] != nil))
  func idleNodeAndCodexRunTogether() async throws {
    let node = NodeBackendClient.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexConcurrent-\(UUID())")
    let service = CodexAppServer(
      executable: URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_FAKE"]!),
      homeDirectory: root)
    do {
      let formatted: SQLFormatResponse = try await node.call(
        method: "sql.format",
        params: SQLFormatRequest(sql: "SELECT 1", engine: "SQLite", offsets: []))
      #expect(!formatted.sql.isEmpty)
      try await Task.sleep(for: .milliseconds(100))
      try await service.start { _, _ in }
      #expect(try await service.account())
      await service.stop()
    } catch {
      await service.stop()
      throw error
    }
  }

  @Test(
    "설치된 Codex에서 민감한 문맥 없이 초기화와 설정을 확인한다",
    .enabled(if: ProcessInfo.processInfo.environment["SOLNARI_TEST_CODEX_REAL"] != nil))
  func realHandshake() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Codex Handshake-\(UUID())")
    let service = CodexAppServer(homeDirectory: root)
    do {
      try await service.start { _, _ in }
      _ = try await service.account()
      #expect(try await !service.prepareThread().isEmpty)
      await service.stop()
    } catch {
      await service.stop()
      throw error
    }
  }
}

@MainActor
struct SQLAssistantModelTests {
  @Test("대화 종료·새 인스턴스는 기록과 공유 선택을 복원하지 않는다")
  func clearingAndStreaming() async throws {
    let fake = FakeAssistantService()
    let assistant = SQLAssistantModel(service: fake)
    assistant.connect()
    while assistant.isBusy { await Task.yield() }
    #expect(assistant.signedIn)
    let defaults = UserDefaults(suiteName: "AssistantTest.\(UUID())")!
    let workspace = WorkspaceModel(profileStore: ConnectionProfileStore(defaults: defaults))
    assistant.draft = "Explain a SELECT statement"
    assistant.send(workspace: workspace)
    while assistant.isBusy { await Task.yield() }
    #expect(assistant.messages.count == 2)
    #expect(assistant.messages.last?.sql == "SELECT 1")
    let sent = try #require(await fake.sent)
    #expect(!sent.contains("resultSample"))
    #expect(!sent.contains("selectedSchema"))
    assistant.includeSQL = true
    assistant.includeRows = true
    assistant.close()
    while assistant.isBusy { await Task.yield() }
    #expect(assistant.messages.isEmpty)
    #expect(!assistant.includeSQL && !assistant.includeRows)
    #expect(SQLAssistantModel(service: fake).messages.isEmpty)
    #expect(SQLAssistantModel.partialExplanation(#"{"explanation":"부분 응답"#) == "부분 응답")
  }
}

private actor FakeAssistantService: CodexAssistantService {
  var sent: String?
  func start(handler: @escaping CodexAppServer.EventHandler) async throws {}
  func account() async throws -> Bool { true }
  func login(deviceCode: Bool) async throws -> CodexJSON { .null }
  func cancelLogin(_ id: String) async {}
  func send(_ prompt: String) async throws -> AsyncThrowingStream<String, any Error> {
    sent = prompt
    return AsyncThrowingStream { continuation in
      continuation.yield(#"{"explanation":"Example","sql":"SELECT 1"}"#)
      continuation.finish()
    }
  }
  func cancelTurn() async { sent = nil }
  func stop() async { sent = nil }
}
