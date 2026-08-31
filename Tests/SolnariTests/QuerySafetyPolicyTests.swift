import Testing

@testable import Solnari

struct QuerySafetyPolicyTests {
  @Test("읽기 전용 정책은 단일 조회 문장만 허용한다")
  func readOnlyAllowsASingleReadStatement() throws {
    try QuerySafetyPolicy.validate(
      sql: "SELECT 'UPDATE users' AS example; -- DELETE is only a comment",
      accessLevel: .readOnly
    )
    try QuerySafetyPolicy.validate(sql: "SHOW TABLES", accessLevel: .readOnly)
  }

  @Test("읽기 전용 정책은 변경·잠금·다중 문장을 fail closed로 거부한다")
  func readOnlyRejectsRiskyStatements() {
    for sql in [
      "UPDATE users SET active = false",
      "SELECT * FROM users FOR UPDATE",
      "SELECT 1; SELECT 2",
      "WITH removed AS (DELETE FROM users RETURNING *) SELECT * FROM removed",
      "PRAGMA query_only = OFF",
    ] {
      #expect(throws: SolnariDatabaseError.self) {
        try QuerySafetyPolicy.validate(sql: sql, accessLevel: .readOnly)
      }
    }
  }

  @Test("읽기·쓰기 정책은 SQL 종류를 클라이언트에서 제한하지 않는다")
  func readWriteLeavesAuthorizationToTheDatabaseRole() throws {
    try QuerySafetyPolicy.validate(
      sql: "CREATE TABLE example (id INTEGER PRIMARY KEY)",
      accessLevel: .readWrite
    )
  }
}
