import Foundation

struct ConnectionProfileStore {
  private let defaults: UserDefaults
  private let legacyStorageKey = "solnari.connectionProfiles.v1"
  private let localStorageKey = "solnari.connectionProfiles.v3"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() throws -> [ConnectionProfile] {
    if let localData = defaults.data(forKey: localStorageKey) {
      return try JSONDecoder().decode([ConnectionProfile].self, from: localData)
        .map { $0.persisted() }
    }

    guard let legacyData = defaults.data(forKey: legacyStorageKey) else { return [] }
    let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: legacyData)
      .map { $0.persisted() }
    try save(profiles)
    return profiles
  }

  func save(_ profiles: [ConnectionProfile]) throws {
    let persistedProfiles = profiles.map { $0.persisted() }
    defaults.set(try JSONEncoder().encode(persistedProfiles), forKey: localStorageKey)
    defaults.removeObject(forKey: legacyStorageKey)
  }
}
