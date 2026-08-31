import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english = "en"
  case korean = "ko"

  var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
  private static let languageKey = "solnari.language"

  @Published var language: AppLanguage {
    didSet {
      UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
    }
  }

  init() {
    let stored = UserDefaults.standard.string(forKey: Self.languageKey)
    language = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
  }

  var effectiveLanguage: AppLanguage {
    guard language == .system else { return language }
    let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
    return preferred.hasPrefix("ko") ? .korean : .english
  }

  var locale: Locale {
    Locale(identifier: effectiveLanguage.rawValue)
  }

  func text(_ key: String) -> String {
    let languageCode = effectiveLanguage.rawValue
    guard let path = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return key
    }
    return bundle.localizedString(forKey: key, value: key, table: nil)
  }
}
