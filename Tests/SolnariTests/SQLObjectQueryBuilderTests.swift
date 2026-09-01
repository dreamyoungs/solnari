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
}
