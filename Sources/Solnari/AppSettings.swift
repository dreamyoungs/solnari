import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english = "en"
  case korean = "ko"

  var id: String { rawValue }
}

enum DisplayTimeZoneOption: String, CaseIterable, Identifiable {
  case system
  case utc = "UTC"
  case seoul = "Asia/Seoul"
  case losAngeles = "America/Los_Angeles"
  case newYork = "America/New_York"
  case london = "Europe/London"

  var id: String { rawValue }

  var label: String {
    self == .system ? "System time zone" : rawValue
  }

  var timeZone: TimeZone {
    self == .system ? .current : TimeZone(identifier: rawValue) ?? .current
  }
}

@MainActor
final class AppSettings: ObservableObject {
  private static let languageKey = "solnari.language"
  private static let displayTimeZoneKey = "solnari.displayTimeZone"

  @Published var language: AppLanguage {
    didSet {
      UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
    }
  }

  @Published var displayTimeZoneOption: DisplayTimeZoneOption {
    didSet {
      UserDefaults.standard.set(displayTimeZoneOption.rawValue, forKey: Self.displayTimeZoneKey)
    }
  }

  init() {
    let stored = UserDefaults.standard.string(forKey: Self.languageKey)
    language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
    let storedTimeZone = UserDefaults.standard.string(forKey: Self.displayTimeZoneKey)
    displayTimeZoneOption =
      storedTimeZone.flatMap(DisplayTimeZoneOption.init(rawValue:)) ?? .system
  }

  var effectiveLanguage: AppLanguage {
    guard language == .system else { return language }
    let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
    return preferred.hasPrefix("ko") ? .korean : .english
  }

  var locale: Locale {
    Locale(identifier: effectiveLanguage.rawValue)
  }

  var displayTimeZone: TimeZone {
    displayTimeZoneOption.timeZone
  }

  func text(_ key: String) -> String {
    let languageCode = effectiveLanguage.rawValue
    guard let path = SolnariResources.bundle.path(forResource: languageCode, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return key
    }
    return bundle.localizedString(forKey: key, value: key, table: nil)
  }
}
