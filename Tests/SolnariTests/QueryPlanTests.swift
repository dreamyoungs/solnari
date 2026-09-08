import Foundation
import Testing

@testable import Solnari

struct QueryPlanTests {
  @Test("엔진별 비실행 계획 명령을 생성하고 원본을 보존한다")
  func dialects() throws {
    for engine in DatabaseEngine.allCases {
      let sql = "SELECT 'semi;colon' AS name; -- tail"
      let command = try QueryPlanBuilder.statement(sql: sql, engine: engine)
      #expect(command == (engine == .sqlite ? "EXPLAIN QUERY PLAN\n" : "EXPLAIN\n") + sql)
    }
    #expect(
      try QueryPlanBuilder.statement(
        sql: "WITH t AS (SELECT 1) SELECT * FROM t", engine: .postgresql
      ).hasPrefix("EXPLAIN\nWITH"))
    #expect(
      try QueryPlanBuilder.statement(sql: "SELECT $tag$; DROP TABLE t;$tag$", engine: .postgresql)
        .hasPrefix("EXPLAIN\n"))
    #expect(
      try QueryPlanBuilder.statement(sql: "SELECT [semi;colon] FROM t", engine: .sqlite).hasPrefix(
        "EXPLAIN QUERY PLAN"))
    #expect(
      try QueryPlanBuilder.statement(
        sql: "/* outer /* inner */ end */ SELECT 1", engine: .postgresql
      ).hasPrefix("EXPLAIN"))
  }

  @Test("다중 문장, 실행형 EXPLAIN, 모호한 따옴표와 주석은 전송 전에 거부한다")
  func unsafeInput() {
    for engine in DatabaseEngine.allCases {
      for sql in [
        "", "-- comment", "SELECT 1; DELETE FROM t", "SELECT 1;;", "EXPLAIN ANALYZE SELECT 1",
        "EXPLAIN (ANALYZE TRUE) DELETE FROM t", "CREATE TABLE t (id int)", "SELECT 'unclosed",
        "SELECT 1 /* unclosed", "SELECT 'a\\'; DELETE FROM t; --'", "SELECT 1 /*!; DROP TABLE t */",
      ] {
        #expect(throws: QueryPlanError.self) {
          try QueryPlanBuilder.statement(sql: sql, engine: engine)
        }
      }
    }
    #expect(throws: QueryPlanError.self) {
      try QueryPlanBuilder.statement(sql: "SELECT 1--x;DELETE FROM t", engine: .mysql)
    }
    #expect(throws: QueryPlanError.self) {
      try QueryPlanBuilder.statement(sql: "SELECT $body$unclosed", engine: .postgresql)
    }
  }

  @Test("SQLite 계획 조회는 변경 문장을 실행하지 않고 오류를 전달한다")
  func sqliteDoesNotMutate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = ConnectionProfile(
      name: "Plan test", database: directory.appendingPathComponent("test.db").path,
      engine: .sqlite, transport: .direct, host: "", port: 0, username: "", requiresTLS: false,
      clientEncoding: "Automatic")
    let backend = DatabaseBackend()
    _ = try await backend.connect(profile: profile, password: "")
    _ = try await backend.execute(
      profileID: profile.id, sql: "CREATE TABLE items (id INTEGER PRIMARY KEY)")
    _ = try await backend.execute(profileID: profile.id, sql: "INSERT INTO items VALUES (1)")
    let plan = try await backend.explain(profileID: profile.id, sql: "SELECT * FROM items")
    #expect(!plan.table.rows.isEmpty)
    _ = try await backend.explain(profileID: profile.id, sql: "DELETE FROM items")
    let count = try await backend.execute(profileID: profile.id, sql: "SELECT COUNT(*) FROM items")
    #expect(count.table.rows == [[.integer(1)]])
    await #expect(throws: (any Error).self) {
      try await backend.explain(profileID: profile.id, sql: "SELECT * FROM missing_table")
    }
    await #expect(throws: QueryPlanError.self) {
      try await backend.explain(profileID: profile.id, sql: "SELECT 1; DELETE FROM items")
    }
    await backend.disconnectAll()
  }

  @Test("취소와 시간 초과는 작업 정리를 한 번 수행하고 늦은 결과를 폐기한다")
  func cancellationAndTimeout() async throws {
    let state = PlanTestState()
    let task = Task {
      try await QueryPlanExecution.run(
        operation: {
          await state.wait()
          return 1
        }, cancel: { await state.cleaned() })
    }
    while !(await state.started) { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await state.cleanups == 1)
    await state.finish()
    let timeoutState = PlanTestState()
    await #expect(throws: QueryPlanError.timedOut) {
      try await QueryPlanExecution.run(
        timeout: .milliseconds(20),
        operation: {
          await timeoutState.wait()
          return 1
        }, cancel: { await timeoutState.cleaned() })
    }
    #expect(await timeoutState.cleanups == 1)
    await timeoutState.finish()
  }
}

private actor PlanTestState {
  var started = false
  var cleanups = 0
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }
  func cleaned() { cleanups += 1 }
  func finish() {
    continuation?.resume()
    continuation = nil
  }
}
