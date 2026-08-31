import Foundation
import SwiftUI

enum DatabaseEngine: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
  case postgresql = "PostgreSQL"
  case mysql = "MySQL"
  case sqlite = "SQLite"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .postgresql: "cylinder.split.1x2"
    case .mysql: "cylinder"
    case .sqlite: "doc.badge.gearshape"
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

struct KubernetesConfiguration: Hashable, Codable, Sendable {
  var context: String
  var namespace: String
  var relayImage: String
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
    auditTextSettings: Bool? = nil
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

struct SchemaObject: Identifiable, Hashable, Sendable {
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

struct EditorTab: Identifiable, Hashable, Sendable {
  let id: UUID
  var title: String
  var sql: String
  var isModified: Bool

  init(id: UUID = UUID(), title: String, sql: String, isModified: Bool = false) {
    self.id = id
    self.title = title
    self.sql = sql
    self.isModified = isModified
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
  var relayImage = "alpine/socat:1.8.0.3"
  var clientEncoding = "Automatic"
  var preferredCharacterSet = "Database default"
  var preferredCollation = "Database default"
  var auditTextSettings = true

  var supportsSelectedTransport: Bool {
    engine != .sqlite || transport == .direct
  }

  var isValid: Bool {
    guard !name.trimmed.isEmpty, supportsSelectedTransport else { return false }
    if engine == .sqlite {
      return !database.trimmed.isEmpty
    }
    guard !host.trimmed.isEmpty, !user.trimmed.isEmpty, Self.isValidPort(port) else {
      return false
    }
    switch transport {
    case .direct:
      return true
    case .cloudSQL:
      return !cloudProject.trimmed.isEmpty && !cloudRegion.trimmed.isEmpty
        && !cloudInstance.trimmed.isEmpty
    case .ssh:
      return !sshHost.trimmed.isEmpty && !sshUser.trimmed.isEmpty && Self.isValidPort(sshPort)
    case .kubernetes:
      return !kubeContext.trimmed.isEmpty && !namespace.trimmed.isEmpty
        && !relayImage.trimmed.isEmpty
    }
  }

  func makeProfile(id: UUID = UUID()) throws -> ConnectionProfile {
    let portNumber = engine == .sqlite ? 0 : (Int(port) ?? 0)
    guard engine == .sqlite || (1...65_535).contains(portNumber) else {
      throw SolnariDatabaseError.invalidPort
    }
    guard supportsSelectedTransport else {
      throw SolnariDatabaseError.unsupportedConnection
    }
    guard isValid else { throw SolnariDatabaseError.incompleteConnection }
    return ConnectionProfile(
      id: id,
      name: name.trimmed,
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
          relayImage: relayImage.trimmed
        ) : nil,
      preferredCharacterSet: preferredCharacterSet,
      preferredCollation: preferredCollation,
      auditTextSettings: auditTextSettings
    )
  }

  private static func isValidPort(_ value: String) -> Bool {
    Int(value).map { (1...65_535).contains($0) } == true
  }
}

struct ConnectionMetadata: Hashable, Sendable {
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
  case missingPassword
  case notConnected
  case invalidServerResponse
  case missingExecutable(String)
  case transportFailed(String)
  case transportTimedOut
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidPort: "Port must be a number between 1 and 65535."
    case .unsupportedConnection: "SQLite supports direct file connections only."
    case .incompleteConnection: "Fill in every required connection field."
    case .missingConnection: "The selected connection no longer exists."
    case .missingPassword: "The password is not available in macOS Keychain."
    case .notConnected: "Connect to the database before running a query."
    case .invalidServerResponse: "The database returned an unexpected response."
    case .missingExecutable(let name): "Install or configure the required \(name) command."
    case .transportFailed(let message): "The connection path failed: \(message)"
    case .transportTimedOut: "The local connection path did not become ready in time."
    case .keychain(let status): "macOS Keychain returned error \(status)."
    }
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
