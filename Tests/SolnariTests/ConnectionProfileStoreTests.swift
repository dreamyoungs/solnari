import Foundation
import Testing

@testable import Solnari

struct ConnectionProfileStoreTests {
  @Test("연결 프로필은 사용자가 입력한 이름을 보존하고 런타임 상태를 초기화한다")
  func profileRoundTripPreservesUserNameAndResetsRuntimeState() throws {
    let suiteName = "SolnariTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConnectionProfileStore(defaults: defaults)
    let profile = ConnectionProfile(
      name: "민석의 개발 DB",
      database: "solnari_test",
      engine: .postgresql,
      transport: .direct,
      host: "127.0.0.1",
      port: 5432,
      username: "solnari",
      requiresTLS: false,
      clientEncoding: "UTF8",
      status: .connected,
      latency: 12,
      serverVersion: "17.2",
      serverEncoding: "UTF8",
      serverTimeZone: "Asia/Seoul",
      preferredCharacterSet: "UTF8",
      preferredCollation: "ko-KR-x-icu",
      auditTextSettings: true,
      securityPolicy: .standard,
      accessLevel: .readOnly
    )

    try store.save([profile])
    let loaded = try #require(store.load().first)

    #expect(loaded.id == profile.id)
    #expect(loaded.name == "민석의 개발 DB")
    #expect(loaded.host == "127.0.0.1")
    #expect(loaded.status == .disconnected)
    #expect(loaded.latency == nil)
    #expect(loaded.serverVersion == nil)
    #expect(loaded.preferredCharacterSet == "UTF8")
    #expect(loaded.preferredCollation == "ko-KR-x-icu")
    #expect(loaded.auditTextSettings == true)
    #expect(loaded.effectiveSecurityPolicy == .standard)
    #expect(loaded.effectiveAccessLevel == .readOnly)
  }

  @Test("연결 초안은 엔진과 네트워크 경로별 필수 입력을 검증한다")
  func draftValidatesEveryEngineAndTransport() throws {
    var draft = ConnectionDraft()
    draft.name = "Local"
    draft.host = "localhost"
    draft.user = "postgres"
    draft.port = "70000"
    #expect(!draft.isValid)
    #expect(throws: (any Error).self) { try draft.makeProfile() }

    draft.port = "3306"
    draft.engine = .mysql
    #expect(draft.isValid)
    #expect(try draft.makeProfile().engine == .mysql)

    draft.transport = .ssh
    #expect(!draft.isValid)
    draft.sshHost = "bastion.example.com"
    draft.sshUser = "ubuntu"
    #expect(draft.isValid)
    let sshProfile = try draft.makeProfile()
    #expect(sshProfile.ssh?.username == "ubuntu")
    #expect(sshProfile.username == "postgres")

    draft.engine = .sqlite
    draft.transport = .cloudSQL
    draft.database = "/tmp/solnari.sqlite"
    #expect(!draft.isValid)
    draft.transport = .direct
    #expect(draft.isValid)

    draft.engine = .postgresql
    draft.port = "5432"
    draft.transport = .kubernetes
    draft.kubeContext = "development"
    draft.namespace = "database-access"
    #expect(!draft.isValid)
    draft.kubernetesResourceName = "admin-db-proxy"
    #expect(draft.isValid)
    let kubernetesProfile = try draft.makeProfile()
    #expect(kubernetesProfile.kubernetes?.effectiveConnectionMode == .existingResource)
    #expect(kubernetesProfile.kubernetes?.resourceKind == .service)
    #expect(kubernetesProfile.kubernetes?.remotePort == 5432)

    draft.transport = .direct
    draft.host = "database.private"
    draft.securityPolicy = .standard
    draft.requiresTLS = false
    #expect(!draft.isValid)
    draft.requiresTLS = true
    #expect(draft.isValid)
  }

  @Test("기존 v1 프로필은 새 경로 설정이 없어도 마이그레이션 없이 읽힌다")
  func legacyProfileDecodesWithoutTransportDetails() throws {
    let json = """
      [{
        "id":"00000000-0000-0000-0000-000000000001",
        "name":"Legacy",
        "database":"postgres",
        "engine":"PostgreSQL",
        "transport":"Direct",
        "host":"localhost",
        "port":5432,
        "username":"postgres",
        "requiresTLS":false,
        "clientEncoding":"UTF8",
        "status":"Disconnected"
      }]
      """
    let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
    #expect(profiles.first?.name == "Legacy")
    #expect(profiles.first?.cloudSQL == nil)
    #expect(profiles.first?.effectiveSecurityPolicy == .localDevelopment)
    #expect(profiles.first?.effectiveAccessLevel == .readWrite)
  }

  @Test("기존 Kubernetes 프로필은 mode 필드가 없으면 임시 relay로 해석한다")
  func legacyKubernetesProfileDefaultsToTemporaryRelay() throws {
    let json = """
      {
        "context":"legacy-context",
        "namespace":"default",
        "relayImage":"alpine/socat:1.8.0.3"
      }
      """
    let configuration = try JSONDecoder().decode(
      KubernetesConfiguration.self,
      from: Data(json.utf8)
    )
    #expect(configuration.effectiveConnectionMode == .temporaryRelay)
  }
}
