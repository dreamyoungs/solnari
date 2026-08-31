import SwiftUI

enum SolnariTheme {
  static let indigo = Color(red: 0.42, green: 0.36, blue: 0.94)
  static let indigoSoft = Color(red: 0.48, green: 0.43, blue: 0.98)
  static let mint = Color(red: 0.20, green: 0.76, blue: 0.55)
  static let orange = Color(red: 0.96, green: 0.57, blue: 0.23)
  static let rose = Color(red: 0.95, green: 0.36, blue: 0.50)

  static let panel = Color(nsColor: .controlBackgroundColor)
  static let elevated = Color(nsColor: .windowBackgroundColor)
  static let sidebar = Color(nsColor: .underPageBackgroundColor)
  static let border = Color.primary.opacity(0.09)
  static let subtleFill = Color.primary.opacity(0.045)
}

struct SolnariMark: View {
  var size: CGFloat = 30

  var body: some View {
    Image("SolnariIcon", bundle: SolnariResources.bundle)
      .resizable()
      .interpolation(.high)
      .frame(width: size, height: size)
      .accessibilityLabel("Solnari")
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
