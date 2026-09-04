import Foundation
import Testing

@testable import Solnari

@MainActor
struct ConnectionProfileTransferTests {
  @Test("내보내기 문서는 버전을 명시하고 비밀정보·내부 ID·런타임 상태를 구조적으로 제외한다")
  func exportExcludesSecretsIdentifiersAndRuntimeState() throws {
    let fixture = try makeWorkspace(profiles: [directProfile(name: "Development")])
    defer { fixture.cleanup() }
    let source = try #require(fixture.workspace.connections.first)
    try fixture.passwordStore.save("transfer-secret-value", for: source.id)
    fixture.workspace.connections[0].status = .connected
    fixture.workspace.connections[0].latency = 18
    fixture.workspace.connections[0].serverVersion = "runtime-server-version"

    let data = try fixture.workspace.exportConnectionProfiles()
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["format"] as? String == ConnectionProfileTransferService.formatIdentifier)
    #expect(json["version"] as? Int == ConnectionProfileTransferService.currentVersion)

    let forbiddenKeys: Set<String> = [
      "id", "password", "token", "credential", "credentialID", "vault", "encryptionKey",
      "status", "latency", "serverVersion", "serverEncoding", "serverTimeZone",
    ]
    #expect(allKeys(in: json).isDisjoint(with: forbiddenKeys))

    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(!encoded.contains(source.id.uuidString))
    #expect(!encoded.contains("transfer-secret-value"))
    #expect(!encoded.contains("runtime-server-version"))
  }

  @Test("지원하는 엔진과 연결 경로는 비밀정보 없는 JSON으로 왕복된다")
  func everySupportedConfigurationRoundTrips() throws {
    let sourceProfiles = supportedProfiles()
    let data = try ConnectionProfileTransferService.encode(sourceProfiles)
    let decodedProfiles = try ConnectionProfileTransferService.decode(data)

    #expect(decodedProfiles.count == sourceProfiles.count)
    for (source, decoded) in zip(sourceProfiles, decodedProfiles) {
      #expect(decoded.id != source.id)
      #expect(decoded.name == source.name)
      #expect(decoded.database == source.database)
      #expect(decoded.engine == source.engine)
      #expect(decoded.transport == source.transport)
      #expect(decoded.host == source.host)
      #expect(decoded.port == source.port)
      #expect(decoded.username == source.username)
      #expect(decoded.requiresTLS == source.requiresTLS)
      #expect(decoded.clientEncoding == source.clientEncoding)
      #expect(decoded.cloudSQL == source.cloudSQL)
      #expect(decoded.ssh == source.ssh)
      #expect(decoded.kubernetes == source.kubernetes)
      #expect(decoded.preferredCharacterSet == source.preferredCharacterSet)
      #expect(decoded.preferredCollation == source.preferredCollation)
      #expect(decoded.auditTextSettings == source.auditTextSettings)
      #expect(decoded.effectiveSecurityPolicy == source.effectiveSecurityPolicy)
      #expect(decoded.effectiveAccessLevel == source.effectiveAccessLevel)
      #expect(decoded.status == .disconnected)
      #expect(decoded.latency == nil)
      #expect(decoded.serverVersion == nil)
    }
  }

  @Test("가져오기는 새 ID를 발급하고 이름 충돌을 조정하며 credential 연결을 만들지 않는다")
  func importCreatesDisconnectedProfilesWithoutCredentialAssociation() throws {
    let existing = directProfile(name: "Development")
    let fixture = try makeWorkspace(profiles: [existing])
    defer { fixture.cleanup() }
    try fixture.passwordStore.save("existing-password", for: existing.id)
    let importedSources = [
      directProfile(name: "development"),
      sqliteProfile(name: "Local archive"),
    ]
    let data = try ConnectionProfileTransferService.encode(importedSources)

    let summary = try fixture.workspace.importConnectionProfiles(data)

    #expect(summary == ConnectionProfileImportSummary(importedCount: 2, renamedCount: 1))
    #expect(
      fixture.workspace.connections.map(\.name) == [
        "Development", "development 2", "Local archive",
      ])
    let imported = Array(fixture.workspace.connections.dropFirst())
    #expect(Set(imported.map(\.id)).isDisjoint(with: [existing.id]))
    #expect(imported.allSatisfy { $0.status == .disconnected })
    #expect(try fixture.passwordStore.password(for: existing.id) == "existing-password")
    for profile in imported {
      #expect(try fixture.passwordStore.password(for: profile.id) == nil)
    }
    #expect(try fixture.profileStore.load().map(\.id) == fixture.workspace.connections.map(\.id))
  }

  @Test("알 수 없는 필드나 잘못된 연결이 있으면 일부 프로필도 가져오지 않는다")
  func invalidDocumentsFailWithoutPartialImport() throws {
    let existing = directProfile(name: "Existing")
    let fixture = try makeWorkspace(profiles: [existing])
    defer { fixture.cleanup() }

    var object = try #require(
      try JSONSerialization.jsonObject(
        with: ConnectionProfileTransferService.encode([directProfile(name: "Imported")])
      ) as? [String: Any]
    )
    var connections = try #require(object["connections"] as? [[String: Any]])
    connections[0]["password"] = "must-be-rejected"
    object["connections"] = connections
    let documentWithSecretField = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ConnectionProfileTransferError.self) {
      try fixture.workspace.importConnectionProfiles(documentWithSecretField)
    }
    #expect(fixture.workspace.connections.map(\.id) == [existing.id])

    object = try #require(
      try JSONSerialization.jsonObject(
        with: ConnectionProfileTransferService.encode([directProfile(name: "Imported")])
      ) as? [String: Any]
    )
    object["version"] = 2
    let unsupportedVersionDocument = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ConnectionProfileTransferError.self) {
      try fixture.workspace.importConnectionProfiles(unsupportedVersionDocument)
    }
    #expect(throws: ConnectionProfileTransferError.self) {
      try fixture.workspace.importConnectionProfiles(Data("{".utf8))
    }
    #expect(fixture.workspace.connections.map(\.id) == [existing.id])

    object = try #require(
      try JSONSerialization.jsonObject(
        with: ConnectionProfileTransferService.encode([
          directProfile(name: "Valid"), directProfile(name: "Invalid"),
        ])
      ) as? [String: Any]
    )
    connections = try #require(object["connections"] as? [[String: Any]])
    connections[1]["database"] = ""
    object["connections"] = connections
    let documentWithInvalidSecondConnection = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ConnectionProfileTransferError.self) {
      try fixture.workspace.importConnectionProfiles(documentWithInvalidSecondConnection)
    }
    #expect(fixture.workspace.connections.map(\.id) == [existing.id])
    #expect(try fixture.profileStore.load().map(\.id) == [existing.id])
  }

  private func makeWorkspace(profiles: [ConnectionProfile]) throws -> WorkspaceFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariTransferTests-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "SolnariTransferTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let profileStore = ConnectionProfileStore(defaults: defaults)
    try profileStore.save(profiles)
    let passwordStore = LocalEncryptedPasswordStore(
      directoryURL: directory.appendingPathComponent("credentials", isDirectory: true)
    )
    return WorkspaceFixture(
      workspace: WorkspaceModel(
        backend: DatabaseBackend(),
        profileStore: profileStore,
        passwordStore: passwordStore
      ),
      profileStore: profileStore,
      passwordStore: passwordStore,
      directory: directory,
      defaults: defaults,
      suiteName: suiteName
    )
  }

  private func supportedProfiles() -> [ConnectionProfile] {
    let commonCharacterSet = "Database default"
    let commonCollation = "Database default"
    return [
      directProfile(name: "PostgreSQL Direct"),
      ConnectionProfile(
        name: "MySQL Direct",
        database: "app",
        engine: .mysql,
        transport: .direct,
        host: "localhost",
        port: 3306,
        username: "app",
        requiresTLS: false,
        clientEncoding: "Automatic",
        preferredCharacterSet: commonCharacterSet,
        preferredCollation: commonCollation,
        auditTextSettings: true,
        securityPolicy: .localDevelopment,
        accessLevel: .readWrite
      ),
      ConnectionProfile(
        name: "PostgreSQL SSH",
        database: "app",
        engine: .postgresql,
        transport: .ssh,
        host: "database.internal",
        port: 5432,
        username: "app",
        requiresTLS: true,
        clientEncoding: "UTF8",
        ssh: SSHConfiguration(host: "bastion.internal", port: 22, username: "operator"),
        preferredCharacterSet: commonCharacterSet,
        preferredCollation: commonCollation,
        auditTextSettings: true,
        securityPolicy: .standard,
        accessLevel: .readOnly
      ),
      cloudSQLProfile(name: "Cloud SQL IAM", useIAM: true),
      cloudSQLProfile(name: "Cloud SQL password", useIAM: false),
      ConnectionProfile(
        name: "Kubernetes resource",
        database: "app",
        engine: .postgresql,
        transport: .kubernetes,
        host: "",
        port: 5432,
        username: "app",
        requiresTLS: false,
        clientEncoding: "UTF8",
        kubernetes: KubernetesConfiguration(
          context: "development",
          namespace: "database-access",
          relayImage: "alpine/socat:1.8.0.3",
          connectionMode: .existingResource,
          resourceKind: .service,
          resourceName: "database-proxy",
          remotePort: 5432
        ),
        preferredCharacterSet: commonCharacterSet,
        preferredCollation: commonCollation,
        auditTextSettings: true,
        securityPolicy: .standard,
        accessLevel: .readOnly
      ),
      ConnectionProfile(
        name: "Kubernetes relay",
        database: "app",
        engine: .mysql,
        transport: .kubernetes,
        host: "database.internal",
        port: 3306,
        username: "app",
        requiresTLS: true,
        clientEncoding: "Automatic",
        kubernetes: KubernetesConfiguration(
          context: "development",
          namespace: "database-access",
          relayImage: "alpine/socat:1.8.0.3",
          connectionMode: .temporaryRelay
        ),
        preferredCharacterSet: commonCharacterSet,
        preferredCollation: commonCollation,
        auditTextSettings: true,
        securityPolicy: .standard,
        accessLevel: .readWrite
      ),
      sqliteProfile(name: "SQLite"),
    ]
  }

  private func directProfile(name: String) -> ConnectionProfile {
    ConnectionProfile(
      name: name,
      database: "app",
      engine: .postgresql,
      transport: .direct,
      host: "localhost",
      port: 5432,
      username: "app",
      requiresTLS: false,
      clientEncoding: "UTF8",
      preferredCharacterSet: "Database default",
      preferredCollation: "Database default",
      auditTextSettings: true,
      securityPolicy: .localDevelopment,
      accessLevel: .readWrite
    )
  }

  private func cloudSQLProfile(name: String, useIAM: Bool) -> ConnectionProfile {
    ConnectionProfile(
      name: name,
      database: "app",
      engine: .postgresql,
      transport: .cloudSQL,
      host: "",
      port: 5432,
      username: "developer@example.com",
      requiresTLS: false,
      clientEncoding: "UTF8",
      cloudSQL: CloudSQLConfiguration(
        project: "solnari-example",
        region: "asia-northeast3",
        instance: "primary",
        useIAMAuthentication: useIAM
      ),
      preferredCharacterSet: "Database default",
      preferredCollation: "Database default",
      auditTextSettings: true,
      securityPolicy: .standard,
      accessLevel: .readOnly
    )
  }

  private func sqliteProfile(name: String) -> ConnectionProfile {
    ConnectionProfile(
      name: name,
      database: "/tmp/solnari-transfer.sqlite",
      engine: .sqlite,
      transport: .direct,
      host: "",
      port: 0,
      username: "",
      requiresTLS: false,
      clientEncoding: "Automatic",
      preferredCharacterSet: "Database default",
      preferredCollation: "Database default",
      auditTextSettings: true,
      securityPolicy: .localDevelopment,
      accessLevel: .readWrite
    )
  }

  private func allKeys(in value: Any) -> Set<String> {
    if let object = value as? [String: Any] {
      return object.reduce(into: Set(object.keys)) { keys, element in
        keys.formUnion(allKeys(in: element.value))
      }
    }
    if let array = value as? [Any] {
      return array.reduce(into: []) { keys, element in
        keys.formUnion(allKeys(in: element))
      }
    }
    return []
  }
}

private struct WorkspaceFixture {
  let workspace: WorkspaceModel
  let profileStore: ConnectionProfileStore
  let passwordStore: LocalEncryptedPasswordStore
  let directory: URL
  let defaults: UserDefaults
  let suiteName: String

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suiteName)
  }
}
