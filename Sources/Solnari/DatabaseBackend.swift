import Foundation

actor DatabaseBackend {
  private let postgresql: PostgreSQLBackend
  private let mysql: MySQLBackend
  private let sqlite: SQLiteBackend
  private let nodeCloudSQL: NodeCloudSQLBackend
  private let transports: ConnectionTransportManager
  private var connectedEngines: [UUID: DatabaseEngine] = [:]
  private var connectedProfiles: [UUID: ConnectionProfile] = [:]

  init(
    postgresql: PostgreSQLBackend = PostgreSQLBackend(),
    mysql: MySQLBackend = MySQLBackend(),
    sqlite: SQLiteBackend = SQLiteBackend(),
    nodeCloudSQL: NodeCloudSQLBackend = NodeCloudSQLBackend(),
    transports: ConnectionTransportManager = ConnectionTransportManager()
  ) {
    self.postgresql = postgresql
    self.mysql = mysql
    self.sqlite = sqlite
    self.nodeCloudSQL = nodeCloudSQL
    self.transports = transports
  }

  func testConnection(profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    try await ConnectionTestDeadline.run(
      timeout: .seconds(connectionTestTimeoutSeconds(for: profile)),
      operation: { [self] in
        try await performConnectionTest(profile: profile, password: password)
      },
      cleanup: { [self] in
        if profile.transport == .cloudSQL {
          await nodeCloudSQL.cancelTestConnection(profileID: profile.id)
        }
        await transports.close(profileID: profile.id)
      }
    )
  }

  private func performConnectionTest(profile: ConnectionProfile, password: String) async throws
    -> ConnectionMetadata
  {
    if profile.transport == .cloudSQL {
      return try await nodeCloudSQL.testConnection(profile: profile, password: password)
    }
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

  private func connectionTestTimeoutSeconds(for profile: ConnectionProfile) -> Int {
    switch profile.transport {
    case .direct: 8
    case .cloudSQL, .ssh: 20
    case .kubernetes:
      profile.kubernetes?.effectiveConnectionMode == .temporaryRelay ? 60 : 20
    }
  }

  func connect(profile: ConnectionProfile, password: String) async throws -> ConnectionMetadata {
    await disconnect(profileID: profile.id)
    if profile.transport == .cloudSQL {
      let metadata = try await nodeCloudSQL.connect(profile: profile, password: password)
      connectedEngines[profile.id] = profile.engine
      connectedProfiles[profile.id] = profile
      return metadata
    }
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
    let profile = connectedProfiles.removeValue(forKey: profileID)
    let engine = connectedEngines.removeValue(forKey: profileID)
    if profile?.transport == .cloudSQL {
      await nodeCloudSQL.disconnect(profileID: profileID)
      await transports.close(profileID: profileID)
      return
    }
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
    await nodeCloudSQL.disconnectAll()
    await transports.closeAll()
  }

  func loadSchema(profileID: UUID) async throws -> SchemaSnapshot {
    if connectedProfiles[profileID]?.transport == .cloudSQL {
      return try await nodeCloudSQL.loadSchema(profileID: profileID)
    }
    return switch try engine(for: profileID) {
    case .postgresql: try await postgresql.loadSchema(profileID: profileID)
    case .mysql: try await mysql.loadSchema(profileID: profileID)
    case .sqlite: try await sqlite.loadSchema(profileID: profileID)
    }
  }

  func loadSchemaObjectDetails(profileID: UUID, object: SchemaObject) async throws
    -> SchemaObjectDetails
  {
    if connectedProfiles[profileID]?.transport == .cloudSQL {
      return try await nodeCloudSQL.loadSchemaObjectDetails(
        profileID: profileID,
        object: object
      )
    }
    return switch try engine(for: profileID) {
    case .postgresql:
      try await postgresql.loadSchemaObjectDetails(profileID: profileID, object: object)
    case .mysql:
      try await mysql.loadSchemaObjectDetails(profileID: profileID, object: object)
    case .sqlite:
      try await sqlite.loadSchemaObjectDetails(profileID: profileID, object: object)
    }
  }

  func execute(profileID: UUID, sql: String) async throws -> QueryExecutionResult {
    guard let profile = connectedProfiles[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    try QuerySafetyPolicy.validate(sql: sql, accessLevel: profile.effectiveAccessLevel)
    if profile.transport == .cloudSQL {
      return try await nodeCloudSQL.execute(profileID: profileID, sql: sql)
    }
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
