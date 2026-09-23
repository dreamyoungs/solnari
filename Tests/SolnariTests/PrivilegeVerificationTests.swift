import Testing

@testable import Solnari

struct PrivilegeVerificationTests {
  @Test("주석과 문자열에 든 GRANT는 실행할 권한 변경으로 간주하지 않는다")
  func classification() {
    #expect(
      QuerySafetyPolicy.containsPrivilegeChange("BEGIN; GRANT SELECT ON items TO reader; COMMIT;"))
    #expect(!QuerySafetyPolicy.containsPrivilegeChange("SELECT 'GRANT SELECT'; -- REVOKE"))
  }

  @Test("가시 범위 내 추가와 제거를 비교하고 잘린 결과로 검증을 주장하지 않는다")
  func differences() throws {
    let columns = ["kind", "object", "grantee", "privilege", "grantable"]
    let row: [QueryCellValue] = [
      .text("table"), .text("items"), .text("reader"), .text("SELECT"), .text("NO"),
    ]
    let empty = QueryTableData(columns: columns, rows: [])
    let populated = QueryTableData(columns: columns, rows: [row])
    #expect(
      PrivilegeVerification.changes(before: empty, after: populated)?.rows == [[.text("+")] + row])
    #expect(
      PrivilegeVerification.changes(before: populated, after: empty)?.rows == [[.text("−")] + row])
    #expect(
      PrivilegeVerification.changes(before: populated, after: populated)?.rows.isEmpty == true)
    #expect(
      PrivilegeVerification.changes(
        before: empty,
        after: QueryTableData(columns: columns, rows: Array(repeating: row, count: 1001))) == nil)
    #expect(PrivilegeVerification.changes(before: empty, after: .empty) == nil)
    try QuerySafetyPolicy.validate(sql: PrivilegeVerification.sql, accessLevel: .readOnly)
  }
}
