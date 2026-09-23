import Foundation

enum PostgreSQLTransactionScript {
  static func statements(_ sql: String) throws -> [String] {
    let statements = try PlanSQLScanner.statements(sql: sql, engine: .postgresql)
    guard statements.count >= 2, QuerySafetyPolicy.startsTransaction(statements[0]),
      let last = try PlanSQLScanner.tokens(sql: statements.last!, engine: .postgresql).first,
      ["COMMIT", "END", "ROLLBACK", "ABORT"].contains(last)
    else { throw TransactionScriptError.incomplete }
    // 한 번의 실행에서 하나의 완결된 트랜잭션만 허용한다. 중간 커밋을
    // 허용하면 뒤 문장 실패 시 전체가 롤백된 것으로 오인할 수 있다.
    for statement in statements.dropFirst().dropLast() {
      let tokens = try PlanSQLScanner.tokens(sql: statement, engine: .postgresql)
      if ["BEGIN", "START", "COMMIT", "END", "ABORT"].contains(tokens.first ?? "")
        || (tokens.first == "ROLLBACK" && !tokens.contains("TO"))
      {
        throw TransactionScriptError.incomplete
      }
    }
    let endTokens = try PlanSQLScanner.tokens(sql: statements.last!, engine: .postgresql)
    guard !endTokens.contains("TO"), !endTokens.contains("CHAIN") else {
      throw TransactionScriptError.incomplete
    }
    return statements
  }
}

enum TransactionScriptError: LocalizedError {
  case incomplete
  var errorDescription: String? {
    "Native PostgreSQL transactions must be run as one complete BEGIN … COMMIT or ROLLBACK script, without intermediate commits or AND CHAIN."
  }
}
