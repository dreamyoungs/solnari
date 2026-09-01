import Testing

@testable import Solnari

struct SingleLineTextTests {
  @Test("한 줄 입력은 원문을 유지한다")
  func preservesSingleLineInput() {
    #expect(SingleLineText.normalized(" app_production ") == " app_production ")
  }

  @Test("여러 줄 입력은 첫 줄만 유지한다")
  func keepsOnlyTheFirstLine() {
    #expect(SingleLineText.normalized("app_production\napp_staging") == "app_production")
    #expect(SingleLineText.normalized("app_production\r\napp_staging") == "app_production")
    #expect(SingleLineText.normalized("app_production\u{2028}app_staging") == "app_production")
  }

  @Test("끝에 붙은 줄바꿈을 제거한다")
  func removesTrailingLineBreak() {
    #expect(SingleLineText.normalized("app_production\n") == "app_production")
  }
}
