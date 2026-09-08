import Foundation

enum QueryPlanError: Error, LocalizedError, Equatable {
  case unsupportedStatement
  case ambiguousSQL
  case multipleStatements
  case timedOut

  var errorDescription: String? {
    switch self {
    case .unsupportedStatement:
      "Explain supports a single SELECT, WITH, INSERT, UPDATE or DELETE statement. Remove any existing EXPLAIN prefix."
    case .ambiguousSQL:
      "Cannot safely inspect this SQL. Check unfinished quotes/comments, backslash escapes and executable comments."
    case .multipleStatements:
      "Explain requires exactly one SQL statement."
    case .timedOut:
      "Query plan timed out. The connection was closed; reconnect to continue."
    }
  }
}

enum QueryPlanBuilder {
  static func statement(sql: String, engine: DatabaseEngine) throws -> String {
    let sql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    let tokens = try PlanSQLScanner.tokens(sql: sql, engine: engine)
    let words = tokens.filter { $0 != ";" }
    guard let first = words.first,
      ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE"].contains(first)
    else { throw QueryPlanError.unsupportedStatement }
    if let end = tokens.firstIndex(of: ";"), end != tokens.count - 1 {
      throw QueryPlanError.multipleStatements
    }
    let prefix = engine == .sqlite ? "EXPLAIN QUERY PLAN" : "EXPLAIN"
    return "\(prefix)\n\(sql)"
  }
}

// 계획 조회에서만 사용하는 보수적인 스캐너입니다. 서버별 escape 설정이 불명확하면 거부합니다.
private enum PlanSQLScanner {
  static func tokens(sql: String, engine: DatabaseEngine) throws -> [String] {
    let chars = Array(sql)
    var i = 0
    var result: [String] = []
    func peek(_ n: Int = 1) -> Character? { i + n < chars.count ? chars[i + n] : nil }
    while i < chars.count {
      let c = chars[i]
      if c.isWhitespace {
        i += 1
        continue
      }
      if (c == "-" && peek() == "-"
        && (engine != .mysql || peek(2) == nil || peek(2)!.isWhitespace))
        || (c == "#" && engine == .mysql)
      {
        while i < chars.count && chars[i] != "\n" && chars[i] != "\r" { i += 1 }
        continue
      }
      if c == "/" && peek() == "*" {
        guard peek(2) != "!", peek(2) != "+" else { throw QueryPlanError.ambiguousSQL }
        i += 2
        var depth = 1
        while i < chars.count && depth > 0 {
          if chars[i] == "/" && peek() == "*" {
            guard engine == .postgresql else { throw QueryPlanError.ambiguousSQL }
            depth += 1
            i += 2
          } else if chars[i] == "*" && peek() == "/" {
            depth -= 1
            i += 2
          } else {
            i += 1
          }
        }
        guard depth == 0 else { throw QueryPlanError.ambiguousSQL }
        continue
      }
      if c == "'" || c == "\"" || c == "`" || (c == "[" && engine == .sqlite) {
        let quote: Character = c == "[" ? "]" : c
        i += 1
        var closed = false
        while i < chars.count {
          guard chars[i] != "\\" else { throw QueryPlanError.ambiguousSQL }
          if chars[i] == quote {
            if quote != "]" && peek() == quote {
              i += 2
              continue
            }
            i += 1
            closed = true
            break
          }
          i += 1
        }
        guard closed else { throw QueryPlanError.ambiguousSQL }
        result.append("<quoted>")
        continue
      }
      if c == "$" && engine == .postgresql {
        let start = i
        var end = i + 1
        while end < chars.count && (chars[end].isLetter || chars[end].isNumber || chars[end] == "_")
        { end += 1 }
        if end < chars.count && chars[end] == "$" {
          let delimiter = Array(chars[start...end])
          i = end + 1
          var closed = false
          while i + delimiter.count <= chars.count {
            if Array(chars[i..<(i + delimiter.count)]) == delimiter {
              i += delimiter.count
              closed = true
              break
            }
            i += 1
          }
          guard closed else { throw QueryPlanError.ambiguousSQL }
          result.append("<quoted>")
          continue
        }
      }
      if c.isLetter || c == "_" {
        let start = i
        i += 1
        while i < chars.count
          && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$")
        { i += 1 }
        result.append(String(chars[start..<i]).uppercased())
      } else {
        result.append(String(c))
        i += 1
      }
    }
    return result
  }
}

// 취소/시간 초과 후 정리가 끝날 때까지 기다려 같은 연결의 재접속과 경합하지 않게 합니다.
private actor QueryPlanCleanup {
  private var task: Task<Void, Never>?
  func run(_ action: @escaping @Sendable () async -> Void) async {
    if task == nil { task = Task { await action() } }
    await task?.value
  }
}

enum QueryPlanExecution {
  static func run<Value: Sendable>(
    timeout: Duration = .seconds(30),
    operation: @escaping @Sendable () async throws -> Value,
    cancel: @escaping @Sendable () async -> Void
  ) async throws -> Value {
    let cleanup = QueryPlanCleanup()
    do {
      return try await ConnectionTestDeadline.run(
        timeout: timeout,
        timeoutError: QueryPlanError.timedOut,
        operation: {
          try Task.checkCancellation()
          return try await operation()
        },
        cleanup: { await cleanup.run(cancel) }
      )
    } catch {
      if Task.isCancelled || (error as? QueryPlanError) == .timedOut {
        await cleanup.run(cancel)
      }
      throw error
    }
  }
}
