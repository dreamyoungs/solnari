import Foundation

struct ConnectionProfileStore {
  private let defaults: UserDefaults
  private let storageKey = "solnari.connectionProfiles.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> [ConnectionProfile] {
    guard let data = defaults.data(forKey: storageKey),
      let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
    else { return [] }
    return profiles.map { $0.persisted() }
  }

  func save(_ profiles: [ConnectionProfile]) throws {
    let data = try JSONEncoder().encode(profiles.map { $0.persisted() })
    defaults.set(data, forKey: storageKey)
  }
}
