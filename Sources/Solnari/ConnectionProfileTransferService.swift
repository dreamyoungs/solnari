import Foundation

struct ConnectionProfileImportSummary: Equatable, Sendable {
  let importedCount: Int
  let renamedCount: Int
}

enum ConnectionProfileTransferError: LocalizedError {
  case documentTooLarge
  case invalidDocument
  case invalidFormat
  case unsupportedVersion(Int)
  case tooManyConnections
  case unknownFields(context: String, fields: [String])
  case invalidConnection(index: Int, reason: String)

  var errorDescription: String? {
    switch self {
    case .documentTooLarge:
      "The connection profile file is larger than the 5 MB limit."
    case .invalidDocument:
      "The selected file is not a valid Solnari connection profile document."
    case .invalidFormat:
      "The selected JSON file is not a Solnari connection profile document."
    case .unsupportedVersion(let version):
      "Connection profile format version \(version) is not supported."
    case .tooManyConnections:
      "A connection profile file can contain at most 1,000 connections."
    case .unknownFields(let context, let fields):
      "Unsupported fields in \(context): \(fields.joined(separator: ", "))."
    case .invalidConnection(let index, let reason):
      "Connection \(index + 1) is invalid: \(reason)"
    }
  }
}

enum ConnectionProfileTransferService {
  static let formatIdentifier = "com.dreamyoungs.solnari.connection-profiles"
  static let currentVersion = 1
  private static let maximumDocumentSize = 5 * 1_024 * 1_024
  private static let maximumConnectionCount = 1_000

  static func encode(_ profiles: [ConnectionProfile]) throws -> Data {
    let document = TransferDocument(
      format: formatIdentifier,
      version: currentVersion,
      connections: profiles.map(TransferConnection.init)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(document)
  }

  static func decode(_ data: Data) throws -> [ConnectionProfile] {
    guard data.count <= maximumDocumentSize else {
      throw ConnectionProfileTransferError.documentTooLarge
    }
    try validateJSONShape(data)

    let document: TransferDocument
    do {
      document = try JSONDecoder().decode(TransferDocument.self, from: data)
    } catch let error as ConnectionProfileTransferError {
      throw error
    } catch {
      throw ConnectionProfileTransferError.invalidDocument
    }

    guard document.format == formatIdentifier else {
      throw ConnectionProfileTransferError.invalidFormat
    }
    guard document.version == currentVersion else {
      throw ConnectionProfileTransferError.unsupportedVersion(document.version)
    }
    guard document.connections.count <= maximumConnectionCount else {
      throw ConnectionProfileTransferError.tooManyConnections
    }

    return try document.connections.enumerated().map { index, connection in
      try connection.makeProfile(index: index)
    }
  }

  private static func validateJSONShape(_ data: Data) throws {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ConnectionProfileTransferError.invalidDocument
    }
    guard let root = object as? [String: Any] else {
      throw ConnectionProfileTransferError.invalidDocument
    }
    try rejectUnknownFields(
      in: root,
      allowed: ["format", "version", "connections"],
      context: "document"
    )
    guard let connections = root["connections"] as? [Any] else {
      throw ConnectionProfileTransferError.invalidDocument
    }

    for (index, value) in connections.enumerated() {
      guard let connection = value as? [String: Any] else {
        throw ConnectionProfileTransferError.invalidDocument
      }
      let context = "connections[\(index)]"
      try rejectUnknownFields(
        in: connection,
        allowed: [
          "name", "database", "engine", "transport", "host", "port", "username",
          "requiresTLS", "clientEncoding", "cloudSQL", "ssh", "kubernetes",
          "preferredCharacterSet", "preferredCollation", "auditTextSettings",
          "securityPolicy", "accessLevel",
        ],
        context: context
      )
      try validateNestedObject(
        connection["cloudSQL"],
        allowed: ["project", "region", "instance", "useIAMAuthentication"],
        context: "\(context).cloudSQL"
      )
      try validateNestedObject(
        connection["ssh"],
        allowed: ["host", "port", "username"],
        context: "\(context).ssh"
      )
      try validateNestedObject(
        connection["kubernetes"],
        allowed: [
          "context", "namespace", "relayImage", "connectionMode", "resourceKind",
          "resourceName", "remotePort",
        ],
        context: "\(context).kubernetes"
      )
    }
  }

  private static func validateNestedObject(
    _ value: Any?,
    allowed: Set<String>,
    context: String
  ) throws {
    guard let value, !(value is NSNull) else { return }
    guard let object = value as? [String: Any] else {
      throw ConnectionProfileTransferError.invalidDocument
    }
    try rejectUnknownFields(in: object, allowed: allowed, context: context)
  }

  private static func rejectUnknownFields(
    in object: [String: Any],
    allowed: Set<String>,
    context: String
  ) throws {
    let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
      throw ConnectionProfileTransferError.unknownFields(context: context, fields: unknown)
    }
  }
}

private struct TransferDocument: Codable {
  let format: String
  let version: Int
  let connections: [TransferConnection]
}

private struct TransferConnection: Codable {
  let name: String
  let database: String
  let engine: DatabaseEngine
  let transport: ConnectionTransport
  let host: String
  let port: Int
  let username: String
  let requiresTLS: Bool
  let clientEncoding: String
  let cloudSQL: TransferCloudSQLConfiguration?
  let ssh: TransferSSHConfiguration?
  let kubernetes: TransferKubernetesConfiguration?
  let preferredCharacterSet: String?
  let preferredCollation: String?
  let auditTextSettings: Bool?
  let securityPolicy: ConnectionSecurityPolicy?
  let accessLevel: DatabaseAccessLevel?

  init(_ profile: ConnectionProfile) {
    name = profile.name
    database = profile.database
    engine = profile.engine
    transport = profile.transport
    host = profile.host
    port = profile.port
    username = profile.username
    requiresTLS = profile.requiresTLS
    clientEncoding = profile.clientEncoding
    cloudSQL = profile.cloudSQL.map(TransferCloudSQLConfiguration.init)
    ssh = profile.ssh.map(TransferSSHConfiguration.init)
    kubernetes = profile.kubernetes.map(TransferKubernetesConfiguration.init)
    preferredCharacterSet = profile.preferredCharacterSet
    preferredCollation = profile.preferredCollation
    auditTextSettings = profile.auditTextSettings
    securityPolicy = profile.securityPolicy
    accessLevel = profile.accessLevel
  }

  func makeProfile(index: Int) throws -> ConnectionProfile {
    do {
      try validateConfiguration(index: index)
      let profile = ConnectionProfile(
        name: name,
        database: database,
        engine: engine,
        transport: transport,
        host: host,
        port: port,
        username: username,
        requiresTLS: requiresTLS,
        clientEncoding: clientEncoding,
        cloudSQL: cloudSQL?.configuration,
        ssh: ssh?.configuration,
        kubernetes: kubernetes?.configuration,
        preferredCharacterSet: preferredCharacterSet,
        preferredCollation: preferredCollation,
        auditTextSettings: auditTextSettings,
        securityPolicy: securityPolicy,
        accessLevel: accessLevel
      )
      let draft = ConnectionDraft(profile: profile)
      if let issue = draft.saveValidationIssues.first {
        throw ConnectionProfileTransferError.invalidConnection(
          index: index,
          reason: issue.message
        )
      }
      return try draft.makeProfile()
    } catch let error as ConnectionProfileTransferError {
      throw error
    } catch {
      throw ConnectionProfileTransferError.invalidConnection(
        index: index,
        reason: error.localizedDescription
      )
    }
  }

  private func validateConfiguration(index: Int) throws {
    let hasCloudSQL = cloudSQL != nil
    let hasSSH = ssh != nil
    let hasKubernetes = kubernetes != nil
    let isConsistent: Bool
    switch transport {
    case .direct:
      isConsistent = !hasCloudSQL && !hasSSH && !hasKubernetes
    case .cloudSQL:
      isConsistent = hasCloudSQL && !hasSSH && !hasKubernetes
    case .ssh:
      isConsistent = !hasCloudSQL && hasSSH && !hasKubernetes
    case .kubernetes:
      isConsistent = !hasCloudSQL && !hasSSH && hasKubernetes
    }
    guard isConsistent else {
      throw ConnectionProfileTransferError.invalidConnection(
        index: index,
        reason: "The transport-specific settings do not match the selected network path."
      )
    }
  }
}

private struct TransferCloudSQLConfiguration: Codable {
  let project: String
  let region: String
  let instance: String
  let useIAMAuthentication: Bool

  init(_ configuration: CloudSQLConfiguration) {
    project = configuration.project
    region = configuration.region
    instance = configuration.instance
    useIAMAuthentication = configuration.useIAMAuthentication
  }

  var configuration: CloudSQLConfiguration {
    CloudSQLConfiguration(
      project: project,
      region: region,
      instance: instance,
      useIAMAuthentication: useIAMAuthentication
    )
  }
}

private struct TransferSSHConfiguration: Codable {
  let host: String
  let port: Int
  let username: String

  init(_ configuration: SSHConfiguration) {
    host = configuration.host
    port = configuration.port
    username = configuration.username
  }

  var configuration: SSHConfiguration {
    SSHConfiguration(host: host, port: port, username: username)
  }
}

private struct TransferKubernetesConfiguration: Codable {
  let context: String
  let namespace: String
  let relayImage: String
  let connectionMode: KubernetesConnectionMode?
  let resourceKind: KubernetesResourceKind?
  let resourceName: String?
  let remotePort: Int?

  init(_ configuration: KubernetesConfiguration) {
    context = configuration.context
    namespace = configuration.namespace
    relayImage = configuration.relayImage
    connectionMode = configuration.connectionMode
    resourceKind = configuration.resourceKind
    resourceName = configuration.resourceName
    remotePort = configuration.remotePort
  }

  var configuration: KubernetesConfiguration {
    KubernetesConfiguration(
      context: context,
      namespace: namespace,
      relayImage: relayImage,
      connectionMode: connectionMode,
      resourceKind: resourceKind,
      resourceName: resourceName,
      remotePort: remotePort
    )
  }
}
