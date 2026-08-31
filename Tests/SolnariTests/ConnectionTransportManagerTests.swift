import Darwin
import Foundation
import Testing

@testable import Solnari

struct ConnectionTransportManagerTests {
  @Test("가짜 CLI로 Cloud SQL, SSH, Kubernetes 경로의 시작과 정리를 검증한다")
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
        cloudSQLProxy: executable.path,
        ssh: executable.path,
        kubectl: executable.path
      ))

    let cloud = profile(
      transport: .cloudSQL,
      cloudSQL: CloudSQLConfiguration(
        project: "project", region: "region", instance: "instance",
        useIAMAuthentication: true
      )
    )
    let cloudEndpoint = try await manager.open(profile: cloud)
    #expect(cloudEndpoint.host == "127.0.0.1")
    await manager.close(profileID: cloud.id)

    let ssh = profile(
      transport: .ssh,
      ssh: SSHConfiguration(host: "bastion", port: 22, username: "ubuntu")
    )
    _ = try await manager.open(profile: ssh)
    await manager.close(profileID: ssh.id)

    let configuration = KubernetesConfiguration(
      context: "test", namespace: "default", relayImage: "fake/socat"
    )
    let kubernetes = profile(transport: .kubernetes, kubernetes: configuration)
    _ = try await manager.open(profile: kubernetes)
    await manager.close(profileID: kubernetes.id)

    let logURL = URL(fileURLWithPath: executable.path + ".log")
    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.contains("--auto-iam-authn"))
    #expect(log.contains("ubuntu@bastion"))
    #expect(log.contains("delete pod/solnari-relay-"))
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
    import socket
    import sys

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
