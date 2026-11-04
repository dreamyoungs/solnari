import Darwin
import Foundation
import Testing

@testable import Solnari

struct ConnectionTransportManagerTests {
  @Test("가짜 CLI로 SSH와 Kubernetes 경로의 시작과 정리를 검증한다")
  func allTransportProcessesStartAndStop() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariTransportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-transport.py")
    try fakeTransportScript.write(to: executable, atomically: true, encoding: .utf8)
    #expect(chmod(executable.path, 0o700) == 0)

    let manager = ConnectionTransportManager(
      executables: TransportExecutables(
        ssh: executable.path,
        kubectl: executable.path
      ))

    let ssh = profile(
      transport: .ssh,
      ssh: SSHConfiguration(host: "bastion", port: 22, username: "ubuntu")
    )
    _ = try await manager.open(profile: ssh)
    #expect(await manager.isRunning(profileID: ssh.id))
    let pidText = try String(contentsOfFile: executable.path + ".pid", encoding: .utf8)
    let pid = try #require(Int32(pidText))
    #expect(Darwin.kill(pid, SIGTERM) == 0)
    for _ in 0..<50 {
      if !(await manager.isRunning(profileID: ssh.id)) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!(await manager.isRunning(profileID: ssh.id)))
    await manager.close(profileID: ssh.id)
    _ = try await manager.open(profile: ssh)
    #expect(await manager.isRunning(profileID: ssh.id))
    await manager.close(profileID: ssh.id)

    let configuration = KubernetesConfiguration(
      context: "test", namespace: "default", relayImage: "fake/socat"
    )
    let kubernetes = profile(transport: .kubernetes, kubernetes: configuration)
    _ = try await manager.open(profile: kubernetes)
    await manager.close(profileID: kubernetes.id)

    let existingResource = profile(
      transport: .kubernetes,
      kubernetes: KubernetesConfiguration(
        context: "test",
        namespace: "database-access",
        relayImage: "",
        connectionMode: .existingResource,
        resourceKind: .service,
        resourceName: "admin-db-proxy",
        remotePort: 5432
      )
    )
    _ = try await manager.open(profile: existingResource)
    await manager.close(profileID: existingResource.id)

    let logURL = URL(fileURLWithPath: executable.path + ".log")
    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.contains("ubuntu@bastion"))
    #expect(log.contains("delete pod/solnari-relay-"))
    #expect(log.contains("port-forward service/admin-db-proxy"))
    #expect(log.contains("--address=127.0.0.1"))
  }

  @Test(
    "설정된 개발 SSH 경로로 PostgreSQL 준비 상태를 확인한다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_TEST_SSH_HOST"] != nil,
      "SOLNARI_TEST_SSH_HOST를 설정하면 실행됩니다."))
  func developmentSSHDatabaseReadiness() async throws {
    let env = ProcessInfo.processInfo.environment
    let host = try #require(env["SOLNARI_TEST_SSH_HOST"])
    let user = try #require(env["SOLNARI_TEST_SSH_USER"])
    let probePath = try #require(env["SOLNARI_TEST_PG_ISREADY"])
    var connection = profile(
      transport: .ssh,
      ssh: SSHConfiguration(
        host: host, port: 22, username: user,
        identityFile: env["SOLNARI_TEST_SSH_KEY"]))
    connection.host = "127.0.0.1"
    connection.port = Int(env["SOLNARI_TEST_SSH_DB_PORT"] ?? "5432") ?? 5432
    let manager = ConnectionTransportManager()
    do {
      let endpoint = try await manager.open(profile: connection)
      #expect(endpoint.host == "127.0.0.1")
      let probe = Process()
      probe.executableURL = URL(fileURLWithPath: probePath)
      probe.arguments = ["-h", endpoint.host, "-p", String(endpoint.port), "-t", "3"]
      probe.standardOutput = FileHandle.nullDevice
      probe.standardError = FileHandle.nullDevice
      try probe.run()
      probe.waitUntilExit()
      #expect(probe.terminationStatus == 0)
      await manager.close(profileID: connection.id)
      #expect(!(await manager.isRunning(profileID: connection.id)))
    } catch {
      await manager.close(profileID: connection.id)
      throw error
    }
  }

  private func profile(
    transport: ConnectionTransport,
    cloudSQL: CloudSQLConfiguration? = nil,
    ssh: SSHConfiguration? = nil,
    kubernetes: KubernetesConfiguration? = nil
  ) -> ConnectionProfile {
    ConnectionProfile(
      name: "Transport test",
      database: "database",
      engine: .postgresql,
      transport: transport,
      host: "database.private",
      port: 5432,
      username: "database-user",
      requiresTLS: false,
      clientEncoding: "UTF8",
      cloudSQL: cloudSQL,
      ssh: ssh,
      kubernetes: kubernetes
    )
  }

  private var fakeTransportScript: String {
    """
    #!/usr/bin/python3
    import os
    import socket
    import sys

    with open(sys.argv[0] + ".pid", "w") as pid_file:
        pid_file.write(str(os.getpid()))

    args = sys.argv[1:]
    with open(sys.argv[0] + ".log", "a", encoding="utf-8") as log:
        log.write(" ".join(args) + "\\n")

    port = None
    for index, arg in enumerate(args):
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
        elif arg == "-L" and index + 1 < len(args):
            port = int(args[index + 1].split(":")[1])
        elif arg == "port-forward" and index + 2 < len(args):
            port = int(args[index + 2].split(":")[0])

    if port is not None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(1)
        while True:
            listener.accept()
    """
  }
}
