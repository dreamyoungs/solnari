import Foundation
import SwiftUI

enum DatabaseEngine: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case postgresql = "PostgreSQL"
  case mysql = "MySQL"
  case sqlite = "SQLite"

  var id: String { rawValue }

  var badgeText: String {
    switch self {
    case .postgresql: "PG"
    case .mysql: "MY"
    case .sqlite: "SQ"
    }
  }

  var badgeAssetName: String {
    switch self {
    case .postgresql: "DatabaseEnginePostgreSQL"
    case .mysql: "DatabaseEngineMySQL"
    case .sqlite: "DatabaseEngineSQLite"
    }
  }

  var tint: Color {
    switch self {
    case .postgresql: SolnariTheme.indigo
    case .mysql: SolnariTheme.orange
    case .sqlite: SolnariTheme.mint
    }
  }
}

enum ConnectionTransport: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case direct = "Direct"
  case cloudSQL = "Cloud SQL"
  case ssh = "SSH Tunnel"
  case kubernetes = "Kubernetes"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .direct: "network"
    case .cloudSQL: "cloud.fill"
    case .ssh: "lock.shield.fill"
    case .kubernetes: "shippingbox.fill"
    }
  }

  var detail: String {
    switch self {
    case .direct: "Connect directly to a host and port"
    case .cloudSQL: "Connect securely with Google IAM"
    case .ssh: "Connect through a bastion host"
    case .kubernetes: "Connect through a kubeconfig context"
    }
  }
}

enum ConnectionStatus: String, Hashable, Codable, Sendable {
  case connecting = "Connecting"
  case connected = "Connected"
  case sleeping = "Sleeping"
  case disconnected = "Disconnected"
  case failed = "Failed"

  var color: Color {
    switch self {
    case .connected: SolnariTheme.mint
    case .connecting, .sleeping: SolnariTheme.orange
    case .failed: .red
    case .disconnected: .secondary
    }
  }
}

enum ConnectionSecurityPolicy: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case localDevelopment = "Local development"
  case standard = "Standard"
  case organizationManaged = "Organization managed"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .localDevelopment: "hammer.fill"
    case .standard: "lock.shield.fill"
    case .organizationManaged: "building.2.crop.circle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .localDevelopment: SolnariTheme.orange
    case .standard: SolnariTheme.mint
    case .organizationManaged: SolnariTheme.indigo
    }
  }

  static var userSelectable: [ConnectionSecurityPolicy] {
    [.localDevelopment, .standard]
  }
}

enum DatabaseAccessLevel: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case readOnly = "Read-only"
  case readWrite = "Read / Write"
  case migration = "Migration"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .readOnly: "eye.fill"
    case .readWrite: "pencil.and.outline"
    case .migration: "arrow.triangle.2.circlepath"
    }
  }

  var tint: Color {
    switch self {
    case .readOnly: SolnariTheme.mint
    case .readWrite: SolnariTheme.orange
    case .migration: .red
    }
  }

  static var userSelectable: [DatabaseAccessLevel] {
    [.readOnly, .readWrite]
  }
}

struct CloudSQLConfiguration: Hashable, Codable, Sendable {
  var project: String
  var region: String
  var instance: String
  var useIAMAuthentication: Bool

  var connectionName: String { "\(project):\(region):\(instance)" }
}

struct SSHConfiguration: Hashable, Codable, Sendable {
  var host: String
  var port: Int
  var username: String
}

enum KubernetesConnectionMode: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case existingResource = "Existing resource"
  case temporaryRelay = "Temporary relay"

  var id: String { rawValue }
}

enum KubernetesResourceKind: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case service = "Service"
  case pod = "Pod"

  var id: String { rawValue }

  var commandName: String { rawValue.lowercased() }
}

struct KubernetesConfiguration: Hashable, Codable, Sendable {
  var context: String
  var namespace: String
  var relayImage: String
  var connectionMode: KubernetesConnectionMode?
  var resourceKind: KubernetesResourceKind?
  var resourceName: String?
  var remotePort: Int?

  var effectiveConnectionMode: KubernetesConnectionMode {
    connectionMode ?? .temporaryRelay
  }

  init(
    context: String,
    namespace: String,
    relayImage: String,
    connectionMode: KubernetesConnectionMode? = nil,
    resourceKind: KubernetesResourceKind? = nil,
    resourceName: String? = nil,
    remotePort: Int? = nil
  ) {
    self.context = context
    self.namespace = namespace
    self.relayImage = relayImage
    self.connectionMode = connectionMode
    self.resourceKind = resourceKind
    self.resourceName = resourceName
    self.remotePort = remotePort
  }
}

struct ConnectionProfile: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  var name: String
  var database: String
  var engine: DatabaseEngine
  var transport: ConnectionTransport
  var host: String
  var port: Int
  var username: String
  var requiresTLS: Bool
  var clientEncoding: String
  var status: ConnectionStatus
  var latency: Int?
  var serverVersion: String?
  var serverEncoding: String?
  var serverTimeZone: String?
  var cloudSQL: CloudSQLConfiguration?
  var ssh: SSHConfiguration?
  var kubernetes: KubernetesConfiguration?
  var preferredCharacterSet: String?
  var preferredCollation: String?
  var auditTextSettings: Bool?
  var securityPolicy: ConnectionSecurityPolicy?
  var accessLevel: DatabaseAccessLevel?

  var effectiveSecurityPolicy: ConnectionSecurityPolicy {
    securityPolicy ?? .localDevelopment
  }

  var effectiveAccessLevel: DatabaseAccessLevel {
    accessLevel ?? .readWrite
  }

  var subtitle: String {
    switch transport {
    case .direct: engine == .sqlite ? database : "\(host):\(port)"
    case .cloudSQL: cloudSQL?.connectionName ?? "Cloud SQL"
    case .ssh: "SSH · \(ssh?.host ?? host)"
    case .kubernetes: "Kubernetes · \(kubernetes?.context ?? host)"
    }
  }

  init(
    id: UUID = UUID(),
    name: String,
    database: String,
    engine: DatabaseEngine,
    transport: ConnectionTransport,
    host: String,
    port: Int,
    username: String,
    requiresTLS: Bool,
    clientEncoding: String,
    status: ConnectionStatus = .disconnected,
    latency: Int? = nil,
    serverVersion: String? = nil,
    serverEncoding: String? = nil,
    serverTimeZone: String? = nil,
    cloudSQL: CloudSQLConfiguration? = nil,
    ssh: SSHConfiguration? = nil,
    kubernetes: KubernetesConfiguration? = nil,
    preferredCharacterSet: String? = nil,
    preferredCollation: String? = nil,
    auditTextSettings: Bool? = nil,
    securityPolicy: ConnectionSecurityPolicy? = nil,
    accessLevel: DatabaseAccessLevel? = nil
  ) {
    self.id = id
    self.name = name
    self.database = database
    self.engine = engine
    self.transport = transport
    self.host = host
    self.port = port
    self.username = username
    self.requiresTLS = requiresTLS
    self.clientEncoding = clientEncoding
    self.status = status
    self.latency = latency
    self.serverVersion = serverVersion
    self.serverEncoding = serverEncoding
    self.serverTimeZone = serverTimeZone
    self.cloudSQL = cloudSQL
    self.ssh = ssh
    self.kubernetes = kubernetes
    self.preferredCharacterSet = preferredCharacterSet
    self.preferredCollation = preferredCollation
    self.auditTextSettings = auditTextSettings
    self.securityPolicy = securityPolicy
    self.accessLevel = accessLevel
  }

  func persisted() -> ConnectionProfile {
    var copy = self
    copy.status = .disconnected
    copy.latency = nil
    copy.serverVersion = nil
    copy.serverEncoding = nil
    copy.serverTimeZone = nil
    return copy
  }
}

enum SchemaObjectKind: String, Hashable, Codable, Sendable {
  case table
  case view
  case materializedView
  case function

  var symbol: String {
    switch self {
    case .table: "tablecells"
    case .view, .materializedView: "eye"
    case .function: "function"
    }
  }
}

struct SchemaObject: Identifiable, Hashable, Codable, Sendable {
  var id: String { "\(schema).\(name).\(kind.rawValue)" }
  let schema: String
  let name: String
  let kind: SchemaObjectKind
  let columnCount: Int

  var qualifiedName: String { "\(schema).\(name)" }

  var metadata: String {
    switch kind {
    case .table: "\(columnCount) columns"
    case .view: "view"
    case .materializedView: "materialized"
    case .function: "function"
    }
  }
}

struct SchemaSnapshot: Hashable, Codable, Sendable {
  let schemas: [String]
  let objects: [SchemaObject]

  static let empty = SchemaSnapshot(schemas: [], objects: [])

  init(schemas: [String], objects: [SchemaObject]) {
    self.schemas = Array(Set(schemas).union(objects.map(\.schema))).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    self.objects = objects
  }
}

struct SchemaColumn: Identifiable, Hashable, Codable, Sendable {
  var id: String { "\(ordinalPosition)-\(name)" }
  let ordinalPosition: Int
  let name: String
  let dataType: String
  let isNullable: Bool
  let defaultValue: String?
  let characterSet: String?
  let collation: String?
  let comment: String?
  let isPrimaryKey: Bool

  var dataTypeDisplay: String { dataType.isEmpty ? "—" : dataType }
  var defaultDisplay: String { defaultValue ?? "—" }
  var textRulesDisplay: String {
    let rules = [characterSet, collation]
      .compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
      .joined(separator: " · ")
    return rules.isEmpty ? "—" : rules
  }
}

struct SchemaIndex: Identifiable, Hashable, Codable, Sendable {
  var id: String { name }
  let name: String
  let columns: [String]
  let isUnique: Bool
  let isPrimary: Bool
  let method: String?
}

enum SchemaConstraintKind: String, Hashable, Codable, Sendable {
  case primaryKey = "Primary key"
  case foreignKey = "Foreign key"
  case unique = "Unique"
  case check = "Check"
  case exclusion = "Exclusion"
  case other = "Other"
}

struct SchemaConstraint: Identifiable, Hashable, Codable, Sendable {
  var id: String { name }
  let name: String
  let kind: SchemaConstraintKind
  let columns: [String]
  let referencedSchema: String?
  let referencedTable: String?
  let referencedColumns: [String]
  let definition: String?

  var referenceDisplay: String {
    guard let referencedTable else { return "" }
    let table = referencedSchema.map { "\($0).\(referencedTable)" } ?? referencedTable
    guard !referencedColumns.isEmpty else { return table }
    return "\(table) (\(referencedColumns.joined(separator: ", ")))"
  }
}

struct SchemaObjectDetails: Hashable, Codable, Sendable {
  let object: SchemaObject
  let columns: [SchemaColumn]
  let indexes: [SchemaIndex]
  let constraints: [SchemaConstraint]
  let definition: String?
}

struct EditorTab: Identifiable, Hashable, Sendable {
  let id: UUID
  var title: String
  var sql: String
  var isModified: Bool
  var sourceObject: SchemaObject?

  init(
    id: UUID = UUID(),
    title: String,
    sql: String,
    isModified: Bool = false,
    sourceObject: SchemaObject? = nil
  ) {
    self.id = id
    self.title = title
    self.sql = sql
    self.isModified = isModified
    self.sourceObject = sourceObject
  }
}

struct ConnectionWorkspace: Hashable, Sendable {
  var schema: SchemaSnapshot
  var editorTabs: [EditorTab]
  var selectedTabID: UUID?
  var queryTable: QueryTableData
  var querySourceObject: SchemaObject?
  var executionMessage: String
  var selectedResultTab: String
  var isRunning: Bool

  init() {
    let query = EditorTab(
      title: "Query 1",
      sql: """
        SELECT
          current_database() AS database,
          current_user AS user,
          now() AS server_time;
        """
    )
    schema = .empty
    editorTabs = [query]
    selectedTabID = query.id
    queryTable = .empty
    querySourceObject = nil
    executionMessage = "No results"
    selectedResultTab = "Results"
    isRunning = false
  }
}

enum MessageRole: Hashable, Sendable {
  case user
  case assistant
}

struct AssistantMessage: Identifiable, Hashable, Sendable {
  let id = UUID()
  let role: MessageRole
  let text: String
  let sql: String?
}

enum ConnectionDraftValidationIssue: Hashable, Sendable {
  case connectionName
  case unsupportedTransport
  case database
  case host
  case port
  case user
  case cloudProject
  case cloudRegion
  case cloudInstance
  case sshHost
  case sshPort
  case sshUser
  case kubernetesContext
  case kubernetesNamespace
  case kubernetesResource
  case kubernetesRemotePort
  case relayImage
  case tlsRequired
  case organizationManagedPolicy
  case migrationAccess

  var message: String {
    switch self {
    case .connectionName: "Enter a connection name before saving."
    case .unsupportedTransport: "SQLite supports direct file connections only."
    case .database: "Enter the database name or choose a SQLite database file."
    case .host: "Enter the database host."
    case .port: "Enter a port number between 1 and 65535."
    case .user: "Enter the database user."
    case .cloudProject: "Enter a valid Google Cloud project ID."
    case .cloudRegion: "Enter a valid Cloud SQL region."
    case .cloudInstance: "Enter the Cloud SQL instance name."
    case .sshHost: "Enter the SSH bastion host."
    case .sshPort: "Enter an SSH port number between 1 and 65535."
    case .sshUser: "Enter the SSH user."
    case .kubernetesContext: "Enter the Kubernetes context."
    case .kubernetesNamespace: "Enter the Kubernetes namespace."
    case .kubernetesResource: "Enter the Kubernetes resource name."
    case .kubernetesRemotePort: "Enter a Kubernetes remote port between 1 and 65535."
    case .relayImage: "Enter the temporary relay image."
    case .tlsRequired: "Enable TLS for a remote direct connection under Standard policy."
    case .organizationManagedPolicy:
      "Organization-managed policy is not available in this build."
    case .migrationAccess: "Migration access is not available in this build."
    }
  }
}

struct ConnectionDraft: Equatable, Sendable {
  var name = ""
  var engine: DatabaseEngine = .postgresql
  var transport: ConnectionTransport = .direct
  var host = "localhost"
  var port = "5432"
  var database = ""
  var user = ""
  var password = ""
  var requiresTLS = false
  var cloudProject = ""
  var cloudRegion = ""
  var cloudInstance = ""
  var useIAM = true
  var sshHost = ""
  var sshPort = "22"
  var sshUser = ""
  var kubeContext = ""
  var namespace = "default"
  var kubernetesMode: KubernetesConnectionMode = .existingResource
  var kubernetesResourceKind: KubernetesResourceKind = .service
  var kubernetesResourceName = ""
  var kubernetesRemotePort = "5432"
  var relayImage = "alpine/socat:1.8.0.3"
  var clientEncoding = "Automatic"
  var preferredCharacterSet = "Database default"
  var preferredCollation = "Database default"
  var auditTextSettings = true
  var securityPolicy: ConnectionSecurityPolicy = .localDevelopment
  var accessLevel: DatabaseAccessLevel = .readWrite

  init() {}

  init(profile: ConnectionProfile) {
    name = profile.name
    engine = profile.engine
    transport = profile.transport
    host = profile.host
    port = profile.engine == .sqlite ? "" : String(profile.port)
    database = profile.database
    user = profile.username
    requiresTLS = profile.requiresTLS
    if let cloudSQL = profile.cloudSQL {
      cloudProject = cloudSQL.project
      cloudRegion = cloudSQL.region
      cloudInstance = cloudSQL.instance
      useIAM = cloudSQL.useIAMAuthentication
    }
    if let ssh = profile.ssh {
      sshHost = ssh.host
      sshPort = String(ssh.port)
      sshUser = ssh.username
    }
    if let kubernetes = profile.kubernetes {
      kubeContext = kubernetes.context
      namespace = kubernetes.namespace
      kubernetesMode = kubernetes.effectiveConnectionMode
      kubernetesResourceKind = kubernetes.resourceKind ?? .service
      kubernetesResourceName = kubernetes.resourceName ?? ""
      kubernetesRemotePort = String(
        kubernetes.remotePort ?? (profile.engine == .mysql ? 3306 : 5432))
      relayImage = kubernetes.relayImage
    }
    clientEncoding = profile.clientEncoding
    preferredCharacterSet = profile.preferredCharacterSet ?? "Database default"
    preferredCollation = profile.preferredCollation ?? "Database default"
    auditTextSettings = profile.auditTextSettings ?? true
    securityPolicy = profile.effectiveSecurityPolicy
    accessLevel = profile.effectiveAccessLevel
  }

  init(
    duplicating profile: ConnectionProfile,
    existingNames: [String],
    copySuffix: String = "Copy"
  ) {
    self.init(profile: profile)
    name = Self.availableCopyName(
      for: profile.name,
      existingNames: existingNames,
      copySuffix: copySuffix
    )
    password = ""
  }

  var supportsSelectedTransport: Bool {
    engine != .sqlite || transport == .direct
  }

  var connectionPassword: String {
    transport == .cloudSQL && useIAM ? "" : password
  }

  var testValidationIssues: [ConnectionDraftValidationIssue] {
    var issues: [ConnectionDraftValidationIssue] = []
    guard supportsSelectedTransport else { return [.unsupportedTransport] }

    if database.trimmed.isEmpty { issues.append(.database) }
    if engine == .sqlite { return issues + policyValidationIssues }

    if user.trimmed.isEmpty { issues.append(.user) }
    switch transport {
    case .direct:
      if host.trimmed.isEmpty { issues.append(.host) }
      if !Self.isValidPort(port) { issues.append(.port) }
    case .cloudSQL:
      if !Self.isValidGoogleCloudProjectID(cloudProject) { issues.append(.cloudProject) }
      if !Self.isValidCloudSQLRegion(cloudRegion) { issues.append(.cloudRegion) }
      if cloudInstance.trimmed.isEmpty { issues.append(.cloudInstance) }
    case .ssh:
      if host.trimmed.isEmpty { issues.append(.host) }
      if !Self.isValidPort(port) { issues.append(.port) }
      if sshHost.trimmed.isEmpty { issues.append(.sshHost) }
      if !Self.isValidPort(sshPort) { issues.append(.sshPort) }
      if sshUser.trimmed.isEmpty { issues.append(.sshUser) }
    case .kubernetes:
      if kubeContext.trimmed.isEmpty { issues.append(.kubernetesContext) }
      if namespace.trimmed.isEmpty { issues.append(.kubernetesNamespace) }
      switch kubernetesMode {
      case .existingResource:
        if kubernetesResourceName.trimmed.isEmpty { issues.append(.kubernetesResource) }
        if !Self.isValidPort(kubernetesRemotePort) { issues.append(.kubernetesRemotePort) }
      case .temporaryRelay:
        if host.trimmed.isEmpty { issues.append(.host) }
        if !Self.isValidPort(port) { issues.append(.port) }
        if relayImage.trimmed.isEmpty { issues.append(.relayImage) }
      }
    }
    return issues + policyValidationIssues
  }

  var saveValidationIssues: [ConnectionDraftValidationIssue] {
    (name.trimmed.isEmpty ? [.connectionName] : []) + testValidationIssues
  }

  var canTestConnection: Bool { testValidationIssues.isEmpty }
  var canSaveConnection: Bool { saveValidationIssues.isEmpty }
  var isValid: Bool { canSaveConnection }

  func makeProfile(id: UUID = UUID()) throws -> ConnectionProfile {
    try makeProfile(id: id, requiresName: true)
  }

  func makeTestProfile(id: UUID = UUID()) throws -> ConnectionProfile {
    try makeProfile(id: id, requiresName: false)
  }

  private func makeProfile(id: UUID, requiresName: Bool) throws -> ConnectionProfile {
    let portNumber = engine == .sqlite ? 0 : (Int(port) ?? 0)
    let usesDatabasePort =
      transport == .direct || transport == .ssh
      || (transport == .kubernetes && kubernetesMode == .temporaryRelay)
    guard engine == .sqlite || !usesDatabasePort || (1...65_535).contains(portNumber) else {
      throw SolnariDatabaseError.invalidPort
    }
    guard supportsSelectedTransport else {
      throw SolnariDatabaseError.unsupportedConnection
    }
    guard requiresName ? canSaveConnection : canTestConnection else {
      throw SolnariDatabaseError.incompleteConnection
    }
    return ConnectionProfile(
      id: id,
      name: name.trimmed.isEmpty ? "Connection test" : name.trimmed,
      database: database.trimmed,
      engine: engine,
      transport: transport,
      host: host.trimmed,
      port: portNumber,
      username: user.trimmed,
      requiresTLS: requiresTLS,
      clientEncoding: clientEncoding,
      cloudSQL: transport == .cloudSQL
        ? CloudSQLConfiguration(
          project: cloudProject.trimmed,
          region: cloudRegion.trimmed,
          instance: cloudInstance.trimmed,
          useIAMAuthentication: useIAM
        ) : nil,
      ssh: transport == .ssh
        ? SSHConfiguration(
          host: sshHost.trimmed,
          port: Int(sshPort) ?? 22,
          username: sshUser.trimmed
        ) : nil,
      kubernetes: transport == .kubernetes
        ? KubernetesConfiguration(
          context: kubeContext.trimmed,
          namespace: namespace.trimmed,
          relayImage: relayImage.trimmed,
          connectionMode: kubernetesMode,
          resourceKind: kubernetesMode == .existingResource ? kubernetesResourceKind : nil,
          resourceName: kubernetesMode == .existingResource
            ? kubernetesResourceName.trimmed : nil,
          remotePort: kubernetesMode == .existingResource
            ? Int(kubernetesRemotePort) : nil
        ) : nil,
      preferredCharacterSet: preferredCharacterSet,
      preferredCollation: preferredCollation,
      auditTextSettings: auditTextSettings,
      securityPolicy: securityPolicy,
      accessLevel: accessLevel
    )
  }

  private var policyValidationIssues: [ConnectionDraftValidationIssue] {
    var issues: [ConnectionDraftValidationIssue] = []
    if securityPolicy == .organizationManaged { issues.append(.organizationManagedPolicy) }
    if accessLevel == .migration { issues.append(.migrationAccess) }
    if securityPolicy == .standard, transport == .direct, engine != .sqlite,
      !Self.isLoopbackHost(host), !requiresTLS
    {
      issues.append(.tlsRequired)
    }
    return issues
  }

  private static func isValidPort(_ value: String) -> Bool {
    Int(value).map { (1...65_535).contains($0) } == true
  }

  private static func isLoopbackHost(_ value: String) -> Bool {
    ["localhost", "127.0.0.1", "::1"].contains(value.trimmed.lowercased())
  }

  private static func isValidGoogleCloudProjectID(_ value: String) -> Bool {
    value.trimmed.range(
      of: #"^[a-z][a-z0-9-]{4,28}[a-z0-9]$"#,
      options: .regularExpression
    ) != nil
  }

  private static func isValidCloudSQLRegion(_ value: String) -> Bool {
    value.trimmed.range(
      of: #"^[a-z]+(?:-[a-z0-9]+)+[0-9]$"#,
      options: .regularExpression
    ) != nil
  }

  private static func availableCopyName(
    for originalName: String,
    existingNames: [String],
    copySuffix: String
  ) -> String {
    let baseName = originalName.trimmed
    let suffix = copySuffix.trimmed.isEmpty ? "Copy" : copySuffix.trimmed
    let copyBase = "\(baseName) \(suffix)"
    let comparisonLocale = Locale(identifier: "en_US_POSIX")
    let occupiedNames = Set(
      existingNames.map {
        $0.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: comparisonLocale
        )
      }
    )

    var candidate = copyBase
    var copyNumber = 2
    while occupiedNames.contains(
      candidate.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: comparisonLocale
      )
    ) {
      candidate = "\(copyBase) \(copyNumber)"
      copyNumber += 1
    }
    return candidate
  }
}

struct ConnectionMetadata: Hashable, Codable, Sendable {
  let latencyMilliseconds: Int
  let serverVersion: String
  let serverEncoding: String
  let serverTimeZone: String
  let database: String
}

struct QueryExecutionResult: Hashable, Sendable {
  let table: QueryTableData
  let durationMilliseconds: Int
}

enum SolnariDatabaseError: LocalizedError, Sendable {
  case invalidPort
  case unsupportedConnection
  case incompleteConnection
  case missingConnection
  case notConnected
  case invalidServerResponse
  case missingExecutable(String)
  case transportFailed(String)
  case transportTimedOut
  case connectionTestTimedOut
  case queryNotAllowedForAccessLevel
  case invalidProfileStore

  var errorDescription: String? {
    switch self {
    case .invalidPort: "Port must be a number between 1 and 65535."
    case .unsupportedConnection: "SQLite supports direct file connections only."
    case .incompleteConnection: "Fill in every required connection field."
    case .missingConnection: "The selected connection no longer exists."
    case .notConnected: "Connect to the database before running a query."
    case .invalidServerResponse: "The database returned an unexpected response."
    case .missingExecutable(let name): "Install or configure the required \(name) command."
    case .transportFailed(let message): "The connection path failed: \(message)"
    case .transportTimedOut: "The local connection path did not become ready in time."
    case .connectionTestTimedOut: "The connection test timed out. Check the address and path."
    case .queryNotAllowedForAccessLevel:
      "This SQL is not allowed by the connection's access level."
    case .invalidProfileStore:
      "The local connection profile store is invalid."
    }
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
