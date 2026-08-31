import Testing

@testable import Solnari

struct TransportCommandBuilderTests {
  @Test("Cloud SQL 연결 이름과 IAM 옵션을 안전한 인자로 구성한다")
  func cloudSQLArguments() throws {
    let profile = networkProfile(
      transport: .cloudSQL,
      cloudSQL: CloudSQLConfiguration(
        project: "sample-project",
        region: "asia-northeast3",
        instance: "primary",
        useIAMAuthentication: true
      )
    )
    let command = try TransportCommandBuilder.cloudSQL(
      executable: "/cloud-sql-proxy", profile: profile, localPort: 15_001
    )
    #expect(command.arguments.contains("--auto-iam-authn"))
    #expect(command.arguments.last == "sample-project:asia-northeast3:primary")
    #expect(!command.arguments.joined().contains("secret"))
  }

  @Test("SSH 포워딩은 DB 계정과 SSH 계정을 분리한다")
  func sshArguments() throws {
    let profile = networkProfile(
      transport: .ssh,
      ssh: SSHConfiguration(host: "bastion.example.com", port: 2222, username: "ubuntu")
    )
    let command = try TransportCommandBuilder.ssh(
      executable: "/usr/bin/ssh", profile: profile, localPort: 15_002
    )
    #expect(command.arguments.contains("127.0.0.1:15002:database.private:5432"))
    #expect(command.arguments.contains("ubuntu@bastion.example.com"))
    #expect(!command.arguments.contains("database_user@bastion.example.com"))
  }

  @Test("Kubernetes 릴레이는 컨텍스트와 네임스페이스를 모든 명령에 명시한다")
  func kubernetesArguments() throws {
    let configuration = KubernetesConfiguration(
      context: "production", namespace: "db-access", relayImage: "alpine/socat:1.8.0.3"
    )
    let profile = networkProfile(transport: .kubernetes, kubernetes: configuration)
    let run = try TransportCommandBuilder.kubernetesRun(
      executable: "/kubectl", profile: profile, relayName: "solnari-relay-test", relayPort: 15_432
    )
    let delete = TransportCommandBuilder.kubernetesDelete(
      executable: "/kubectl", configuration: configuration, relayName: "solnari-relay-test"
    )
    for command in [run, delete] {
      #expect(
        command.arguments.starts(with: ["--context", "production", "--namespace", "db-access"]))
    }
    #expect(delete.arguments.contains("--ignore-not-found=true"))
  }

  private func networkProfile(
    transport: ConnectionTransport,
    cloudSQL: CloudSQLConfiguration? = nil,
    ssh: SSHConfiguration? = nil,
    kubernetes: KubernetesConfiguration? = nil
  ) -> ConnectionProfile {
    ConnectionProfile(
      name: "Test",
      database: "app",
      engine: .postgresql,
      transport: transport,
      host: "database.private",
      port: 5432,
      username: "database_user",
      requiresTLS: false,
      clientEncoding: "UTF8",
      cloudSQL: cloudSQL,
      ssh: ssh,
      kubernetes: kubernetes
    )
  }
}
