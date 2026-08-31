import Foundation

struct ConnectionProfileStore {
  private struct ProfileIndex: Codable {
    let version: Int
    let profileIDs: [UUID]
  }

  private let defaults: UserDefaults
  private let vault: any ConnectionProfileVault
  private let legacyStorageKey = "solnari.connectionProfiles.v1"
  private let indexStorageKey = "solnari.connectionProfileIndex.v2"

  init(
    defaults: UserDefaults = .standard,
    vault: any ConnectionProfileVault = KeychainConnectionProfileVault()
  ) {
    self.defaults = defaults
    self.vault = vault
  }

  func load() throws -> [ConnectionProfile] {
    if let indexData = defaults.data(forKey: indexStorageKey) {
      let index = try JSONDecoder().decode(ProfileIndex.self, from: indexData)
      guard index.version == 2 else { throw SolnariDatabaseError.invalidProfileStore }
      return try index.profileIDs.map { profileID in
        guard let profile = try vault.profile(for: profileID) else {
          throw SolnariDatabaseError.invalidProfileStore
        }
        return profile.persisted()
      }
    }

    guard let legacyData = defaults.data(forKey: legacyStorageKey) else { return [] }
    let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: legacyData)
      .map { $0.persisted() }
    for profile in profiles {
      try vault.save(profile)
    }
    try saveIndex(profiles.map(\.id))
    defaults.removeObject(forKey: legacyStorageKey)
    return profiles
  }

  func save(_ profiles: [ConnectionProfile]) throws {
    let persistedProfiles = profiles.map { $0.persisted() }
    let previousIDs = currentIndex()?.profileIDs ?? []
    for profile in persistedProfiles {
      try vault.save(profile)
    }
    try saveIndex(persistedProfiles.map(\.id))
    defaults.removeObject(forKey: legacyStorageKey)

    let retainedIDs = Set(persistedProfiles.map(\.id))
    for removedID in previousIDs where !retainedIDs.contains(removedID) {
      try vault.delete(profileID: removedID)
    }
  }

  private func currentIndex() -> ProfileIndex? {
    guard let data = defaults.data(forKey: indexStorageKey) else { return nil }
    return try? JSONDecoder().decode(ProfileIndex.self, from: data)
  }

  private func saveIndex(_ profileIDs: [UUID]) throws {
    let data = try JSONEncoder().encode(ProfileIndex(version: 2, profileIDs: profileIDs))
    defaults.set(data, forKey: indexStorageKey)
  }
}
