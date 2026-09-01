import Foundation
import Testing

@testable import Solnari

@MainActor
struct ResultColumnWidthCalculatorTests {
  @Test("컬럼 내용 맞춤은 헤더와 셀 중 긴 값에 맞춘다")
  func fitsHeaderAndCellContent() {
    let short = ResultColumnWidthCalculator.fittedWidth(
      title: "ID",
      values: [.integer(1)],
      displayTimeZone: .gmt
    )
    let long = ResultColumnWidthCalculator.fittedWidth(
      title: "Description",
      values: [.text("A considerably longer database result value")],
      displayTimeZone: .gmt
    )

    #expect(short == ResultColumnWidthCalculator.minimumWidth)
    #expect(long > short)
  }

  @Test("지나치게 긴 셀은 결과 그리드 전체를 밀어내지 않는다")
  func capsVeryLongValues() {
    let width = ResultColumnWidthCalculator.fittedWidth(
      title: "Payload",
      values: [.text(String(repeating: "wide-value-", count: 100))],
      displayTimeZone: .gmt
    )

    #expect(width == ResultColumnWidthCalculator.maximumWidth)
  }
}
