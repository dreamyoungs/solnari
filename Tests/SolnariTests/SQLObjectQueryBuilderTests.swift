import Testing

@testable import Solnari

struct SQLObjectQueryBuilderTests {
  @Test("엔진별 식별자를 안전하게 인용해 테이블 조회 SQL을 만든다")
  func selectAllQuotesIdentifiersForEveryEngine() {
    let object = SchemaObject(
      schema: "reporting",
      name: "order\"items`archive",
      kind: .table,
      columnCount: 3
    )

    #expect(
      SQLObjectQueryBuilder.selectAll(from: object, engine: .postgresql)
        .contains("\"reporting\".\"order\"\"items`archive\"")
    )
    #expect(
      SQLObjectQueryBuilder.selectAll(from: object, engine: .mysql)
        .contains("`reporting`.`order\"items``archive`")
    )
    #expect(
      SQLObjectQueryBuilder.selectAll(from: object, engine: .sqlite, limit: 9_999)
        .hasSuffix("LIMIT 1000;")
    )
  }

  @Test("결과 셀 값으로 안전한 SELECT 조건을 만든다")
  func selectMatchingBuildsTypedPredicates() throws {
    let object = SchemaObject(schema: "public", name: "order-items", kind: .table, columnCount: 3)

    let equal = try #require(
      SQLObjectQueryBuilder.selectMatching(
        from: object,
        column: "customer'name",
        value: .text("O'Reilly"),
        action: .equal,
        engine: .postgresql
      ))
    #expect(equal.contains(#"WHERE "customer'name" = 'O''Reilly'"#))

    let null = try #require(
      SQLObjectQueryBuilder.selectMatching(
        from: object,
        column: "deleted_at",
        value: .null,
        action: .equal,
        engine: .postgresql
      ))
    #expect(null.contains(#"WHERE "deleted_at" IS NULL"#))

    let contains = try #require(
      SQLObjectQueryBuilder.selectMatching(
        from: object,
        column: "title",
        value: .text("50%_off"),
        action: .contains,
        engine: .postgresql
      ))
    #expect(contains.contains(#"LIKE '%50\%\_off%' ESCAPE E'\\'"#))
  }

  @Test("삭제는 실행하지 않고 검토용 SQL로 생성한다")
  func deleteMatchingBuildsReviewableSQL() throws {
    let object = SchemaObject(schema: "main", name: "items", kind: .table, columnCount: 2)

    let sql = try #require(
      SQLObjectQueryBuilder.deleteMatching(
        from: object,
        column: "id",
        value: .integer(42),
        engine: .sqlite
      ))
    #expect(sql.hasPrefix("-- Review before running"))
    #expect(sql.contains(#"DELETE FROM "main"."items""#))
    #expect(sql.contains(#"WHERE "id" = 42;"#))
    #expect(
      SQLObjectQueryBuilder.deleteMatching(
        from: object,
        column: "payload",
        value: .binary(byteCount: 12),
        engine: .sqlite
      ) == nil)
  }

  @Test("단일 테이블 SELECT에서 결과의 원본 객체를 추론한다")
  func infersSourceOnlyForUnambiguousSingleTableSelects() {
    let items = SchemaObject(schema: "public", name: "order-items", kind: .table, columnCount: 3)
    let users = SchemaObject(schema: "public", name: "users", kind: .table, columnCount: 2)
    let objects = [items, users]

    #expect(
      SQLObjectQueryBuilder.inferredSourceObject(
        from: #"SELECT * FROM "public"."order-items" WHERE "id" = 1"#,
        objects: objects,
        engine: .postgresql
      ) == items)
    #expect(
      SQLObjectQueryBuilder.inferredSourceObject(
        from: "SELECT id FROM users",
        objects: objects,
        engine: .postgresql
      ) == users)
    #expect(
      SQLObjectQueryBuilder.inferredSourceObject(
        from: "SELECT * FROM users JOIN other ON other.id = users.id",
        objects: objects,
        engine: .postgresql
      ) == nil)
  }
}
