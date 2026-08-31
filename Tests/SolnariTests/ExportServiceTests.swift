import Foundation
import Testing

@testable import Solnari

struct ExportServiceTests {
  @Test("표준 내보내기는 절대 시간과 시간대 없는 값을 구분한다")
  func canonicalExportKeepsInstantOffsetAndZoneLessTimestampUnchanged() {
    let instant = Date(timeIntervalSince1970: 0)
    let localTimestamp = Date(timeIntervalSince1970: 946_684_800)
    let table = QueryTableData(
      columns: ["instant", "local_time"],
      rows: [[.instant(instant), .localTimestamp(localTimestamp)]]
    )

    let csv = ResultExporter.string(from: table, format: .csv)
    #expect(csv.contains("1970-01-01T00:00:00.000000Z"))
    #expect(csv.contains("2000-01-01 00:00:00.000000"))
    #expect(!csv.contains("2000-01-01T00:00:00.000000Z"))
  }

  @Test("JSON 내보내기는 null, 불리언, 숫자 타입을 보존한다")
  func jsonPreservesNullBooleanAndNumericValues() throws {
    let table = QueryTableData(
      columns: ["count", "price", "enabled", "note"],
      rows: [[.integer(42), .decimal("19.95"), .boolean(true), .null]]
    )

    let data = try #require(
      ResultExporter.string(from: table, format: .json).data(using: .utf8))
    let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let object = try #require(objects.first)
    #expect(object["count"] as? Int == 42)
    #expect(object["price"] as? Double == 19.95)
    #expect(object["enabled"] as? Bool == true)
    #expect(object["note"] is NSNull)
  }

  @Test("중복된 결과 컬럼은 JSON 내보내기에서 안전한 고유 키를 사용한다")
  func duplicateColumnsUseStableUniqueJSONKeys() throws {
    let table = QueryTableData(
      columns: ["id", "id", "id"],
      rows: [[.integer(1), .integer(2), .integer(3)]]
    )

    let data = try #require(
      ResultExporter.string(from: table, format: .json).data(using: .utf8))
    let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let object = try #require(objects.first)
    #expect(object["id"] as? Int == 1)
    #expect(object["id_2"] as? Int == 2)
    #expect(object["id_3"] as? Int == 3)
  }
}
