import AppKit
import SwiftUI
import Testing

@testable import Solnari

@MainActor
struct DatabaseEngineBadgeTests {
  @Test("데이터베이스 엔진은 색상 외에도 고유한 짧은 표기를 가진다")
  func enginesHaveStableDistinctLabels() {
    #expect(DatabaseEngine.postgresql.badgeText == "PG")
    #expect(DatabaseEngine.mysql.badgeText == "MY")
    #expect(DatabaseEngine.sqlite.badgeText == "SQ")
    #expect(Set(DatabaseEngine.allCases.map(\.badgeText)).count == DatabaseEngine.allCases.count)
  }

  @Test("엔진 배지는 작은 크기와 접근성 표시 상태에서도 렌더링된다")
  func badgesRenderAcrossSupportedVisualStates() throws {
    for size in DatabaseEngineBadgeSize.allCases {
      for engine in DatabaseEngine.allCases {
        let light = try renderedBadge(engine: engine, size: size)
        let dark = try renderedBadge(engine: engine, size: size, colorScheme: .dark)
        let highContrast = try renderedBadge(
          engine: engine,
          size: size,
          appearanceOverride: .accessible
        )
        let disabled = try renderedBadge(engine: engine, size: size, disabled: true)

        #expect(!light.isEmpty)
        #expect(!dark.isEmpty)
        #expect(!highContrast.isEmpty)
        #expect(!disabled.isEmpty)
      }
    }

    let engineRenderings = try DatabaseEngine.allCases.map {
      try renderedBadge(engine: $0, size: .sidebar)
    }
    #expect(Set(engineRenderings).count == DatabaseEngine.allCases.count)
  }

  private func renderedBadge(
    engine: DatabaseEngine,
    size: DatabaseEngineBadgeSize,
    colorScheme: ColorScheme = .light,
    appearanceOverride: DatabaseEngineBadgeAppearance? = nil,
    disabled: Bool = false
  ) throws -> Data {
    let content = DatabaseEngineBadge(
      engine: engine,
      size: size,
      appearanceOverride: appearanceOverride
    )
    .environment(\.colorScheme, colorScheme)
    .disabled(disabled)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    #expect(image.size == NSSize(width: size.width, height: size.height))
    return try #require(image.tiffRepresentation)
  }
}
