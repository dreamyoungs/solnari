import SwiftUI

enum SolnariTheme {
  static let indigo = Color(red: 0.42, green: 0.36, blue: 0.94)
  static let indigoSoft = Color(red: 0.48, green: 0.43, blue: 0.98)
  static let mint = Color(red: 0.20, green: 0.76, blue: 0.55)
  static let orange = Color(red: 0.96, green: 0.57, blue: 0.23)
  static let rose = Color(red: 0.95, green: 0.36, blue: 0.50)

  static let panel = Color(nsColor: .controlBackgroundColor)
  static let elevated = Color(nsColor: .windowBackgroundColor)
  static let sidebar = Color(
    nsColor: NSColor(name: NSColor.Name("SolnariSidebar")) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.105, green: 0.10, blue: 0.14, alpha: 1)
        : NSColor(srgbRed: 0.968, green: 0.963, blue: 0.985, alpha: 1)
    })
  static let sidebarElevated = Color(
    nsColor: NSColor(name: NSColor.Name("SolnariSidebarElevated")) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.135, green: 0.13, blue: 0.17, alpha: 1)
        : NSColor(srgbRed: 0.987, green: 0.984, blue: 0.995, alpha: 1)
    })
  static let border = Color.primary.opacity(0.09)
  static let subtleFill = Color.primary.opacity(0.045)
}

struct SolnariMark: View {
  var size: CGFloat = 30

  @ViewBuilder
  var body: some View {
    if let iconURL = SolnariResources.bundle.url(
      forResource: "SolnariIcon",
      withExtension: "png"
    ), let icon = NSImage(contentsOf: iconURL) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
        .accessibilityLabel("Solnari")
    } else {
      Image(systemName: "camera.macro")
        .font(.system(size: size * 0.78, weight: .semibold))
        .foregroundStyle(SolnariTheme.indigo)
        .frame(width: size, height: size)
        .accessibilityLabel("Solnari")
    }
  }
}

struct StatusDot: View {
  let color: Color
  var size: CGFloat = 7

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: size, height: size)
      .overlay(Circle().stroke(color.opacity(0.22), lineWidth: 4))
  }
}

enum DatabaseEngineBadgeSize: CaseIterable, Sendable {
  case inline
  case picker
  case sidebar
  case guide

  var width: CGFloat {
    switch self {
    case .inline: 24
    case .picker: 28
    case .sidebar: 31
    case .guide: 34
    }
  }

  var height: CGFloat {
    switch self {
    case .inline: 17
    case .picker: 20
    case .sidebar: 31
    case .guide: 34
    }
  }

}

struct DatabaseEngineBadgeAppearance: Equatable, Sendable {
  let increasedContrast: Bool
  let differentiateWithoutColor: Bool

  static let accessible = DatabaseEngineBadgeAppearance(
    increasedContrast: true,
    differentiateWithoutColor: true
  )
}

struct DatabaseEngineBadge: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.isEnabled) private var isEnabled

  let engine: DatabaseEngine
  var size: DatabaseEngineBadgeSize = .sidebar
  var appearanceOverride: DatabaseEngineBadgeAppearance? = nil

  @ViewBuilder
  var body: some View {
    Group {
      if let badgeImage {
        Image(nsImage: badgeImage)
          .resizable()
          .renderingMode(.original)
          .interpolation(.high)
          .antialiased(true)
          .scaledToFit()
      } else {
        Text(engine.badgeText)
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(engine.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    }
    .frame(width: size.width, height: size.height)
    .contrast(usesAccessibleOutline ? 1.16 : 1)
    .saturation(isEnabled ? 1 : 0.12)
    .opacity(isEnabled ? 1 : 0.55)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(engine.rawValue)
  }

  private var badgeImage: NSImage? {
    guard
      let url = SolnariResources.bundle.url(
        forResource: engine.badgeAssetName,
        withExtension: "png"
      )
    else {
      return nil
    }
    return NSImage(contentsOf: url)
  }

  private var usesIncreasedContrast: Bool {
    appearanceOverride?.increasedContrast ?? (contrast == .increased)
  }

  private var usesAccessibleOutline: Bool {
    usesIncreasedContrast
      || (appearanceOverride?.differentiateWithoutColor ?? differentiateWithoutColor)
  }
}

struct DatabaseEnginePill: View {
  @EnvironmentObject private var settings: AppSettings
  let engine: DatabaseEngine

  var body: some View {
    HStack(spacing: 5) {
      DatabaseEngineBadge(engine: engine, size: .inline)
        .accessibilityHidden(true)
      Text(settings.text(engine.rawValue))
        .font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(engine.tint)
    .padding(.trailing, 8)
    .padding(.vertical, 3)
    .background(engine.tint.opacity(0.09), in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(engine.rawValue)
  }
}

struct PillLabel: View {
  @EnvironmentObject private var settings: AppSettings
  let title: String
  let symbol: String?
  var tint: Color = .secondary

  init(_ title: String, symbol: String? = nil, tint: Color = .secondary) {
    self.title = title
    self.symbol = symbol
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: 5) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: 10, weight: .semibold))
      }
      Text(settings.text(title))
        .font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(tint.opacity(0.09), in: Capsule())
  }
}

extension View {
  func panelSurface(cornerRadius: CGFloat = 10) -> some View {
    self
      .background(
        SolnariTheme.elevated, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(SolnariTheme.border)
      )
  }
}
