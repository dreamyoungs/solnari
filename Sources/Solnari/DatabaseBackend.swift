import Foundation

actor DatabaseBackend {
  private let postgresql: PostgreSQLBackend
  private let mysql: MySQLBackend
  private let sqlite: SQLiteBackend
  private let nodeCloudSQL: NodeCloudSQLBackend
  private let transports: ConnectionTransportManager
  private var connectedEngines: [UUID: DatabaseEngine] = [:]
  private var connectedProfiles: [UUID: ConnectionProfile] = [:]
  private var resolvedProfiles: [UUID: ConnectionProfile] = [:]
  // Reservations include sessions that are still opening, so concurrent opens cannot exceed the limit.
  private var mcpParentIDs: [UUID: UUID] = [:]

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
      let credential = profile.usesPersonalIAM ? try await nodeCloudSQL.loginToken() : password
      let metadata = try await testEngine(resolved, password: credential)
      await transports.close(profileID: profile.id)
      return metadata
    } catch {
      await transports.close(profileID: profile.id)
      if profile.transport == .ssh, !(error is CancellationError) {
        throw SolnariDatabaseError.transportFailed(
          "SSH tunnel opened, but the database session failed. Check the database host and port on the SSH server, database credentials and TLS settings, then reconnect."
        )
      }
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
      resolvedProfiles[profile.id] = profile
      return metadata
    }
    let endpoint = try await transports.open(profile: profile)
    let resolved = resolvedProfile(profile, endpoint: endpoint)
    do {
      let credential = profile.usesPersonalIAM ? try await nodeCloudSQL.loginToken() : password
      let metadata = try await connectEngine(resolved, password: credential)
      connectedEngines[profile.id] = profile.engine
      connectedProfiles[profile.id] = profile
      resolvedProfiles[profile.id] = resolved
      return metadata
    } catch {
      await transports.close(profileID: profile.id)
      if profile.transport == .ssh, !(error is CancellationError) {
        throw SolnariDatabaseError.transportFailed(
          "SSH tunnel opened, but the database session failed. Check the database host and port on the SSH server, database credentials and TLS settings, then reconnect."
        )
      }
      throw error
    }
  }

  /// Each request owns a fresh database session; credentials and transport remain app-owned.
  func openMCPSession(
    parentID: UUID, password: String, requiredAccessLevel: DatabaseAccessLevel? = nil
  ) async throws -> UUID {
    guard let profile = connectedProfiles[parentID], let resolved = resolvedProfiles[parentID],
      mcpParentIDs[parentID] == nil
    else { throw SolnariDatabaseError.notConnected }
    if let requiredAccessLevel, profile.effectiveAccessLevel != requiredAccessLevel {
      throw SolnariDatabaseError.queryNotAllowedForAccessLevel
    }
    guard
      mcpParentIDs.values.filter({ $0 == parentID }).count
        < profile.effectiveMCPMaxConcurrentQueries
    else {
      throw MCPAccessError.sessionLimitReached
    }
    let sessionID = UUID()
    mcpParentIDs[sessionID] = parentID
    let child = resolved.sessionProfile(id: sessionID, database: profile.database)
    connectedProfiles[sessionID] = child
    connectedEngines[sessionID] = child.engine
    do {
      _ = try await engine(for: parentID)
      try Task.checkCancellation()
      guard mcpParentIDs[sessionID] == parentID, connectedProfiles[parentID] != nil,
        connectedProfiles[sessionID] != nil
      else { throw SolnariDatabaseError.notConnected }
      if profile.transport == .cloudSQL {
        _ = try await nodeCloudSQL.connect(profile: child, password: password)
      } else {
        let credential = profile.usesPersonalIAM ? try await nodeCloudSQL.loginToken() : password
        guard mcpParentIDs[sessionID] == parentID, connectedProfiles[parentID] != nil,
          connectedProfiles[sessionID] != nil
        else { throw SolnariDatabaseError.notConnected }
        _ = try await connectEngine(child, password: credential, maximumConnections: 1)
      }
      try Task.checkCancellation()
      guard mcpParentIDs[sessionID] == parentID, connectedProfiles[parentID] != nil else {
        throw SolnariDatabaseError.notConnected
      }
      return sessionID
    } catch {
      await disconnect(profileID: sessionID)
      throw error
    }
  }

  func openDatabase(profile: ConnectionProfile, password: String) async throws
    -> (metadata: ConnectionMetadata, schema: SchemaSnapshot)
  {
    try await ConnectionTestDeadline.run(
      timeout: .seconds(connectionTestTimeoutSeconds(for: profile)),
      timeoutError: SolnariDatabaseError.databaseSwitchTimedOut,
      operation: { [self] in
        do {
          let metadata = try await connect(profile: profile, password: password)
          try Task.checkCancellation()
          let schema = try await loadSchema(profileID: profile.id)
          try Task.checkCancellation()
          return (metadata, schema)
        } catch {
          await disconnect(profileID: profile.id)
          throw error
        }
      },
      cleanup: { await self.disconnect(profileID: profile.id) }
    )
  }

  func disconnect(profileID: UUID) async {
    let profile = connectedProfiles.removeValue(forKey: profileID)
    let engine = connectedEngines.removeValue(forKey: profileID)
    resolvedProfiles.removeValue(forKey: profileID)
    let isMCPSession = mcpParentIDs[profileID] != nil
    // Keep the reservation until the physical session has finished closing.
    defer { mcpParentIDs.removeValue(forKey: profileID) }
    let children = mcpParentIDs.filter { $0.value == profileID }.map(\.key)
    for child in children { await disconnect(profileID: child) }
    if profile?.transport == .cloudSQL {
      await nodeCloudSQL.disconnect(profileID: profileID)
      if !isMCPSession { await transports.close(profileID: profileID) }
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
    if !isMCPSession { await transports.close(profileID: profileID) }
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
    return switch try await engine(for: profileID) {
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
    return switch try await engine(for: profileID) {
    case .postgresql:
      try await postgresql.loadSchemaObjectDetails(profileID: profileID, object: object)
    case .mysql:
      try await mysql.loadSchemaObjectDetails(profileID: profileID, object: object)
    case .sqlite:
      try await sqlite.loadSchemaObjectDetails(profileID: profileID, object: object)
    }
  }

  func execute(
    profileID: UUID, sql: String, requiredAccessLevel: DatabaseAccessLevel? = nil
  ) async throws -> QueryExecutionResult {
    guard let profile = connectedProfiles[profileID] else {
      throw SolnariDatabaseError.notConnected
    }
    if let requiredAccessLevel, profile.effectiveAccessLevel != requiredAccessLevel {
      throw SolnariDatabaseError.queryNotAllowedForAccessLevel
    }
    try QuerySafetyPolicy.validate(sql: sql, accessLevel: profile.effectiveAccessLevel)
    if profile.transport == .cloudSQL {
      return try await nodeCloudSQL.execute(profileID: profileID, sql: sql)
    }
    do {
      switch try await engine(for: profileID) {
      case .postgresql: return try await postgresql.execute(profileID: profileID, sql: sql)
      case .mysql: return try await mysql.execute(profileID: profileID, sql: sql)
      case .sqlite: return try await sqlite.execute(profileID: profileID, sql: sql)
      }
    } catch {
      // 전송 중 끊겼다면 결과는 불확실합니다. 복구나 SQL 재실행은 시도하지 않습니다.
      if profile.transport == .ssh {
        _ = try await engine(for: profileID)
      }
      throw error
    }
  }

  func explain(profileID: UUID, sql: String) async throws -> QueryExecutionResult {
    let statement = try QueryPlanBuilder.statement(sql: sql, engine: await engine(for: profileID))
    return try await QueryPlanExecution.run(
      operation: { try await self.execute(profileID: profileID, sql: statement) },
      cancel: { await self.disconnect(profileID: profileID) }
    )
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

  private func connectEngine(
    _ profile: ConnectionProfile, password: String, maximumConnections: Int = 4
  ) async throws
    -> ConnectionMetadata
  {
    switch profile.engine {
    case .postgresql:
      try await postgresql.connect(
        profile: profile, password: password, maximumConnections: maximumConnections)
    case .mysql: try await mysql.connect(profile: profile, password: password)
    case .sqlite: try await sqlite.connect(profile: profile)
    }
  }

  private func engine(for profileID: UUID) async throws -> DatabaseEngine {
    if connectedProfiles[profileID]?.transport == .ssh,
      !(await transports.isRunning(profileID: mcpParentIDs[profileID] ?? profileID))
    {
      throw SolnariDatabaseError.sshTunnelDisconnected
    }
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
