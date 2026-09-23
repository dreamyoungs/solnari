import Testing

@testable import Solnari

struct PostgreSQLTransactionScriptTests {
  @Test("문자열·달러 인용·중첩 주석의 세미콜론을 트랜잭션 경계로 해석하지 않는다")
  func boundaries() throws {
    let sql = """
      /* outer /* ; */ comment */ BEGIN;
      SELECT 'quoted;value', $$ BEGIN; END; $$;
      DO $body$ BEGIN RAISE NOTICE 'sample'; END $body$;
      COMMIT; -- tail
      """
    let statements = try PostgreSQLTransactionScript.statements(sql)
    #expect(statements.count == 4)
    #expect(statements[1].contains("'quoted;value'"))
    #expect(statements[2].contains("RAISE NOTICE"))
  }

  @Test("미완료·중간 커밋·새 트랜잭션을 여는 스크립트는 실행 전에 거부한다")
  func boundariesMustBeComplete() {
    for sql in [
      "BEGIN", "BEGIN; SELECT 1", "BEGIN; COMMIT; SELECT 1; COMMIT",
      "BEGIN; COMMIT AND CHAIN", "BEGIN; ROLLBACK TO savepoint", "BEGIN; SELECT 'unclosed; COMMIT",
    ] {
      #expect(throws: (any Error).self) { try PostgreSQLTransactionScript.statements(sql) }
    }
  }
}
