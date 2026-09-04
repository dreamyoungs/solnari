import Foundation
import Testing

@testable import Solnari

@MainActor
struct ConnectionDuplicationTests {
  @Test("연결 복제는 저장이나 연결 없이 새 UUID의 편집 초안을 연다")
  func duplicationPresentsUnsavedDraftWithoutCredentialAssociation() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariDuplicationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let suiteName = "SolnariDuplicationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profileStore = ConnectionProfileStore(defaults: defaults)
    let passwordStore = LocalEncryptedPasswordStore(
      directoryURL: directory.appendingPathComponent("credentials", isDirectory: true)
    )
    let source = profile(name: "Orders", engine: .postgresql, transport: .direct)
    let firstCopy = profile(name: "Orders Copy", engine: .postgresql, transport: .direct)
    let secondCopy = profile(name: "orders copy 2", engine: .postgresql, transport: .direct)
    try profileStore.save([source, firstCopy, secondCopy])
    try passwordStore.save("source-only-password", for: source.id)

    let workspace = WorkspaceModel(
      backend: DatabaseBackend(),
      profileStore: profileStore,
      passwordStore: passwordStore
    )
    let originalSelection = workspace.selectedConnectionID

    workspace.beginDuplicatingConnection(source.id)

    let draft = try #require(workspace.presentedConnectionDraft)
    let duplicateID = try #require(workspace.newConnectionProfileID)
    #expect(workspace.showNewConnection)
    #expect(workspace.editingConnection == nil)
    #expect(workspace.connections.count == 3)
    #expect(workspace.selectedConnectionID == originalSelection)
    #expect(draft.name == "Orders Copy 3")
    #expect(draft.password.isEmpty)
    #expect(duplicateID != source.id)
    #expect(try passwordStore.password(for: source.id) == "source-only-password")
    #expect(try passwordStore.password(for: duplicateID) == nil)
    #expect(try profileStore.load().map(\.id) == [source.id, firstCopy.id, secondCopy.id])
  }

  @Test("복제 초안은 지원 연결별 비밀정보와 런타임 상태를 제외하고 구성을 복사한다")
  func duplicationCopiesSupportedConfigurationOnly() throws {
    let profiles = supportedProfiles()

    for source in profiles {
      var runtimeSource = source
      runtimeSource.status = .connected
      runtimeSource.latency = 14
      runtimeSource.serverVersion = "runtime-version"
      runtimeSource.serverEncoding = "runtime-encoding"
      runtimeSource.serverTimeZone = "runtime-zone"

      let draft = ConnectionDraft(
        duplicating: runtimeSource,
        existingNames: profiles.map(\.name),
        copySuffix: "Copy"
      )
      let duplicate = try draft.makeProfile()

      #expect(duplicate.id != source.id)
      #expect(draft.password.isEmpty)
      #expect(duplicate.engine == source.engine)
      #expect(duplicate.transport == source.transport)
      #expect(duplicate.database == source.database)
      #expect(duplicate.host == source.host)
      #expect(duplicate.port == source.port)
      #expect(duplicate.username == source.username)
      #expect(duplicate.requiresTLS == source.requiresTLS)
      #expect(duplicate.clientEncoding == source.clientEncoding)
      #expect(duplicate.cloudSQL == source.cloudSQL)
      #expect(duplicate.ssh == source.ssh)
      #expect(duplicate.kubernetes == source.kubernetes)
      #expect(
        duplicate.preferredCharacterSet
          == (source.preferredCharacterSet ?? "Database default"))
      #expect(
        duplicate.preferredCollation
          == (source.preferredCollation ?? "Database default"))
      #expect(duplicate.auditTextSettings == (source.auditTextSettings ?? true))
      #expect(duplicate.effectiveSecurityPolicy == source.effectiveSecurityPolicy)
      #expect(duplicate.effectiveAccessLevel == source.effectiveAccessLevel)
      #expect(duplicate.status == .disconnected)
      #expect(duplicate.latency == nil)
      #expect(duplicate.serverVersion == nil)
      #expect(duplicate.serverEncoding == nil)
      #expect(duplicate.serverTimeZone == nil)
    }
  }

  @Test("복사본 이름은 언어별 접미사와 대소문자 충돌을 예측 가능하게 처리한다")
  func duplicationNameSupportsLocalizedSuffixAndCollisions() {
    let source = profile(name: "분석 DB", engine: .mysql, transport: .direct)
    let draft = ConnectionDraft(
      duplicating: source,
      existingNames: ["분석 DB", "분석 DB 복사본", "분석 db 복사본 2"],
      copySuffix: "복사본"
    )

    #expect(draft.name == "분석 DB 복사본 3")
  }

  private func supportedProfiles() -> [ConnectionProfile] {
    [
      profile(name: "PostgreSQL Direct", engine: .postgresql, transport: .direct),
      profile(name: "MySQL Direct", engine: .mysql, transport: .direct),
      ConnectionProfile(
        name: "MySQL SSH",
        database: "app",
        engine: .mysql,
        transport: .ssh,
        host: "database.example",
        port: 3306,
        username: "app",
        requiresTLS: true,
        clientEncoding: "Automatic",
        ssh: SSHConfiguration(host: "bastion.example", port: 22, username: "operator")
      ),
      ConnectionProfile(
        name: "Cloud SQL",
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
          useIAMAuthentication: true
        ),
        securityPolicy: .standard,
        accessLevel: .readOnly
      ),
      ConnectionProfile(
        name: "Cloud SQL Password",
        database: "app",
        engine: .mysql,
        transport: .cloudSQL,
        host: "",
        port: 3306,
        username: "app",
        requiresTLS: false,
        clientEncoding: "Automatic",
        cloudSQL: CloudSQLConfiguration(
          project: "solnari-example",
          region: "asia-northeast3",
          instance: "primary",
          useIAMAuthentication: false
        ),
        securityPolicy: .standard
      ),
      ConnectionProfile(
        name: "Kubernetes",
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
        securityPolicy: .standard
      ),
      ConnectionProfile(
        name: "Kubernetes Relay",
        database: "app",
        engine: .mysql,
        transport: .kubernetes,
        host: "database.example",
        port: 3306,
        username: "app",
        requiresTLS: true,
        clientEncoding: "Automatic",
        kubernetes: KubernetesConfiguration(
          context: "development",
          namespace: "database-access",
          relayImage: "alpine/socat:1.8.0.3",
          connectionMode: .temporaryRelay,
          resourceKind: nil,
          resourceName: nil,
          remotePort: nil
        ),
        securityPolicy: .standard
      ),
      ConnectionProfile(
        name: "SQLite",
        database: "/tmp/solnari-duplication.sqlite",
        engine: .sqlite,
        transport: .direct,
        host: "",
        port: 0,
        username: "",
        requiresTLS: false,
        clientEncoding: "Automatic"
      ),
    ]
  }

  private func profile(
    name: String,
    engine: DatabaseEngine,
    transport: ConnectionTransport
  ) -> ConnectionProfile {
    ConnectionProfile(
      name: name,
      database: "app",
      engine: engine,
      transport: transport,
      host: "localhost",
      port: engine == .mysql ? 3306 : 5432,
      username: "app",
      requiresTLS: false,
      clientEncoding: "Automatic"
    )
  }
}
