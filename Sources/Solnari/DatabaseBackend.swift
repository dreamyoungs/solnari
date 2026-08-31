import Foundation

actor DatabaseBackend {
  private let postgresql: PostgreSQLBackend
  private let mysql: MySQLBackend
  private let sqlite: SQLiteBackend
  private let transports: ConnectionTransportManager
  private var connectedEngines: [UUID: DatabaseEngine] = [:]
  private var connectedProfiles: [UUID: ConnectionProfile] = [:]

  init(
    postgresql: PostgreSQLBackend = PostgreSQLBackend(),
    mysql: MySQLBackend = MySQLBackend(),
    sqlite: SQLiteBackend = SQLiteBackend(),
    transports: ConnectionTransportManager = ConnectionTransportManager()
  ) {
    self.postgresql = postgresql
    self.mysql = mysql
    self.sqlite = sqlite
    self.transports = transports
  }

  func testConnection(profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    let endpoint = try await transports.open(profile: profile)
    let resolved = resolvedProfile(profile, endpoint: endpoint)
    do {
      let metadata = try await testEngine(resolved, password: password)
      await transports.close(profileID: profile.id)
      return metadata
    } catch {
      await transports.close(profileID: profile.id)
      throw error
    }
  }

  func connect(profile: ConnectionProfile, password: String) async throws -> ConnectionMetadata {
    await disconnect(profileID: profile.id)
    let endpoint = try await transports.open(profile: profile)
    let resolved = resolvedProfile(profile, endpoint: endpoint)
    do {
      let metadata = try await connectEngine(resolved, password: password)
      connectedEngines[profile.id] = profile.engine
      connectedProfiles[profile.id] = profile
      return metadata
    } catch {
      await transports.close(profileID: profile.id)
      throw error
    }
  }

  func disconnect(profileID: UUID) async {
    connectedProfiles.removeValue(forKey: profileID)
    let engine = connectedEngines.removeValue(forKey: profileID)
    switch engine {
    case .postgresql: await postgresql.disconnect(profileID: profileID)
    case .mysql: await mysql.disconnect(profileID: profileID)
    case .sqlite: await sqlite.disconnect(profileID: profileID)
    case nil:
      await postgresql.disconnect(profileID: profileID)
      await mysql.disconnect(profileID: profileID)
      await sqlite.disconnect(profileID: profileID)
    }
    await transports.close(profileID: profileID)
  }

  func disconnectAll() async {
    let profileIDs = Array(connectedEngines.keys)
    for profileID in profileIDs {
      await disconnect(profileID: profileID)
    }
    await transports.closeAll()
  }

  func loadSchema(profileID: UUID) async throws -> [SchemaObject] {
    switch try engine(for: profileID) {
    case .postgresql: try await postgresql.loadSchema(profileID: profileID)
    case .mysql: try await mysql.loadSchema(profileID: profileID)
    case .sqlite: try await sqlite.loadSchema(profileID: profileID)
    }
  }

  func execute(profileID: UUID, sql: String) async throws -> QueryExecutionResult {
    guard let profile = connectedProfiles[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    try QuerySafetyPolicy.validate(sql: sql, accessLevel: profile.effectiveAccessLevel)
    switch try engine(for: profileID) {
    case .postgresql: return try await postgresql.execute(profileID: profileID, sql: sql)
    case .mysql: return try await mysql.execute(profileID: profileID, sql: sql)
    case .sqlite: return try await sqlite.execute(profileID: profileID, sql: sql)
    }
  }

  private func testEngine(_ profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    switch profile.engine {
    case .postgresql: try await postgresql.testConnection(profile: profile, password: password)
    case .mysql: try await mysql.testConnection(profile: profile, password: password)
    case .sqlite: try await sqlite.testConnection(profile: profile)
    }
  }

  private func connectEngine(_ profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    switch profile.engine {
    case .postgresql: try await postgresql.connect(profile: profile, password: password)
    case .mysql: try await mysql.connect(profile: profile, password: password)
    case .sqlite: try await sqlite.connect(profile: profile)
    }
  }

  private func engine(for profileID: UUID) throws -> DatabaseEngine {
    guard let engine = connectedEngines[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    return engine
  }

  private func resolvedProfile(_ profile: ConnectionProfile, endpoint: TransportEndpoint)
    -> ConnectionProfile
  {
    var copy = profile
    copy.host = endpoint.host
    copy.port = endpoint.port
    if profile.transport == .cloudSQL {
      copy.requiresTLS = false
    }
    return copy
  }
}
