import Foundation

enum PrivilegeVerification {
  // 사용자 SQL을 보간하지 않는 읽기 전용 카탈로그 조회다. 이 범위 밖의
  // 권한(예: 함수, 컬럼, 기본 권한)이나 다른 세션의 변경을 검증했다고 주장하지 않는다.
  static let sql = """
    SELECT 'membership' AS kind, role.rolname::text AS object,
           member.rolname::text AS grantee, 'MEMBER'::text AS privilege,
           membership.admin_option::text AS grantable
      FROM pg_catalog.pg_auth_members membership
      JOIN pg_catalog.pg_roles role ON role.oid = membership.roleid
      JOIN pg_catalog.pg_roles member ON member.oid = membership.member
    UNION ALL
    SELECT 'table', quote_ident(table_catalog) || '.' || quote_ident(table_schema) || '.' || quote_ident(table_name),
           grantee, privilege_type, is_grantable
      FROM information_schema.table_privileges
     WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
    ORDER BY 1, 2, 3, 4, 5
    LIMIT 1001
    """

  static func changes(before: QueryTableData, after: QueryTableData) -> QueryTableData? {
    guard before.columns == after.columns, before.columns.count == 5,
      before.rows.count <= 1000, after.rows.count <= 1000
    else { return nil }
    let old = Set(before.rows)
    let new = Set(after.rows)
    let removed = before.rows.filter { !new.contains($0) }.map { [QueryCellValue.text("−")] + $0 }
    let added = after.rows.filter { !old.contains($0) }.map { [QueryCellValue.text("+")] + $0 }
    return QueryTableData(columns: ["Change"] + after.columns, rows: removed + added)
  }
}
