import Testing

@testable import Solnari

@MainActor
struct SettingsNavigationTests {
  @Test("설정 목적지는 해당 탭을 선택하고 연결 프로필은 일반 탭의 보안 UI를 재사용한다")
  func destinationSelectsExpectedTab() {
    let settings = AppSettings()

    settings.selectSettingsDestination(.mcp)
    #expect(settings.selectedSettingsTab == .mcp)

    settings.selectSettingsDestination(.about)
    #expect(settings.selectedSettingsTab == .about)

    settings.selectSettingsDestination(.connectionProfiles)
    #expect(settings.selectedSettingsTab == .general)

    settings.selectSettingsDestination(.general)
    #expect(settings.selectedSettingsTab == .general)
  }
}
