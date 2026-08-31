import Darwin
import Foundation

struct TransportEndpoint: Hashable, Sendable {
  let host: String
  let port: Int
}

struct TransportCommand: Hashable, Sendable {
  let executable: String
  let arguments: [String]
}

enum TransportCommandBuilder {
  static func cloudSQL(
    executable: String, profile: ConnectionProfile, localPort: Int
  ) throws -> TransportCommand {
    guard let configuration = profile.cloudSQL else {
      throw SolnariDatabaseError.incompleteConnection
    }
    var arguments = [
      "--address=127.0.0.1",
      "--port=\(localPort)",
      "--quiet",
    ]
    if configuration.useIAMAuthentication {
      arguments.append("--auto-iam-authn")
    }
    arguments.append(configuration.connectionName)
    return TransportCommand(executable: executable, arguments: arguments)
  }

  static func ssh(
    executable: String, profile: ConnectionProfile, localPort: Int
  ) throws -> TransportCommand {
    guard let configuration = profile.ssh else {
      throw SolnariDatabaseError.incompleteConnection
    }
    return TransportCommand(
      executable: executable,
      arguments: [
        "-N", "-T",
        "-o", "BatchMode=yes",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-p", String(configuration.port),
        "-L", "127.0.0.1:\(localPort):\(profile.host):\(profile.port)",
        "\(configuration.username)@\(configuration.host)",
      ]
    )
  }

  static func kubernetesRun(
    executable: String, profile: ConnectionProfile, relayName: String, relayPort: Int
  ) throws -> TransportCommand {
    guard let configuration = profile.kubernetes else {
      throw SolnariDatabaseError.incompleteConnection
    }
    return TransportCommand(
      executable: executable,
      arguments: kubePrefix(configuration) + [
        "run", relayName,
        "--image=\(configuration.relayImage)",
        "--restart=Never",
        "--command", "--",
        "socat",
        "TCP-LISTEN:\(relayPort),fork,reuseaddr",
        "TCP:\(profile.host):\(profile.port)",
      ]
    )
  }

  static func kubernetesWait(
    executable: String, configuration: KubernetesConfiguration, relayName: String
  ) -> TransportCommand {
    TransportCommand(
      executable: executable,
      arguments: kubePrefix(configuration) + [
        "wait", "--for=condition=Ready", "pod/\(relayName)", "--timeout=45s",
      ]
    )
  }

  static func kubernetesForward(
    executable: String,
    configuration: KubernetesConfiguration,
    relayName: String,
    localPort: Int,
    relayPort: Int
  ) -> TransportCommand {
    TransportCommand(
      executable: executable,
      arguments: kubePrefix(configuration) + [
        "port-forward", "pod/\(relayName)", "\(localPort):\(relayPort)",
        "--address=127.0.0.1",
      ]
    )
  }

  static func kubernetesDelete(
    executable: String, configuration: KubernetesConfiguration, relayName: String
  ) -> TransportCommand {
    TransportCommand(
      executable: executable,
      arguments: kubePrefix(configuration) + [
        "delete", "pod/\(relayName)", "--ignore-not-found=true", "--wait=false",
      ]
    )
  }

  static func kubernetesExistingResourceForward(
    executable: String,
    configuration: KubernetesConfiguration,
    localPort: Int
  ) throws -> TransportCommand {
    guard let resourceKind = configuration.resourceKind,
      let resourceName = configuration.resourceName?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !resourceName.isEmpty,
      let remotePort = configuration.remotePort,
      (1...65_535).contains(remotePort)
    else {
      throw SolnariDatabaseError.incompleteConnection
    }
    return TransportCommand(
      executable: executable,
      arguments: kubePrefix(configuration) + [
        "port-forward", "\(resourceKind.commandName)/\(resourceName)",
        "\(localPort):\(remotePort)", "--address=127.0.0.1",
      ]
    )
  }

  private static func kubePrefix(_ configuration: KubernetesConfiguration) -> [String] {
    ["--context", configuration.context, "--namespace", configuration.namespace]
  }
}

struct TransportExecutables: Sendable {
  var cloudSQLProxy: String?
  var ssh: String?
  var kubectl: String?

  static let system = TransportExecutables()
}

actor ConnectionTransportManager {
  private struct Session {
    var processes: [Process]
    var cleanup: TransportCommand?
  }

  private var sessions: [UUID: Session] = [:]
  private let executables: TransportExecutables

  init(executables: TransportExecutables = .system) {
    self.executables = executables
  }

  deinit {
    for session in sessions.values {
      for process in session.processes where process.isRunning {
        process.terminate()
      }
      if let cleanup = session.cleanup {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cleanup.executable)
        process.arguments = cleanup.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
      }
    }
  }

  func open(profile: ConnectionProfile) async throws -> TransportEndpoint {
    await close(profileID: profile.id)
    switch profile.transport {
    case .direct:
      return TransportEndpoint(host: profile.host, port: profile.port)
    case .cloudSQL:
      return try await openCloudSQL(profile)
    case .ssh:
      return try await openSSH(profile)
    case .kubernetes:
      return try await openKubernetes(profile)
    }
  }

  func close(profileID: UUID) async {
    guard let session = sessions.removeValue(forKey: profileID) else { return }
    for process in session.processes where process.isRunning {
      await terminate(process)
    }
    if let cleanup = session.cleanup {
      _ = try? await run(cleanup)
    }
  }

  func closeAll() async {
    let profileIDs = Array(sessions.keys)
    for profileID in profileIDs {
      await close(profileID: profileID)
    }
  }

  private func terminate(_ process: Process) async {
    guard process.isRunning else { return }
    process.terminate()
    for _ in 0..<20 {
      if !process.isRunning { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    for _ in 0..<10 where process.isRunning {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private func openCloudSQL(_ profile: ConnectionProfile) async throws -> TransportEndpoint {
    let executable =
      try executables.cloudSQLProxy
      ?? ExecutableResolver.resolve(
        name: "cloud-sql-proxy", environmentKey: "SOLNARI_CLOUD_SQL_PROXY"
      )
    let port = try Self.availablePort()
    let command = try TransportCommandBuilder.cloudSQL(
      executable: executable, profile: profile, localPort: port
    )
    let process = try start(command)
    sessions[profile.id] = Session(processes: [process], cleanup: nil)
    do {
      try await waitUntilListening(port: port, process: process)
      return TransportEndpoint(host: "127.0.0.1", port: port)
    } catch {
      await close(profileID: profile.id)
      throw error
    }
  }

  private func openSSH(_ profile: ConnectionProfile) async throws -> TransportEndpoint {
    let executable =
      try executables.ssh
      ?? ExecutableResolver.resolve(name: "ssh", environmentKey: "SOLNARI_SSH")
    let port = try Self.availablePort()
    let command = try TransportCommandBuilder.ssh(
      executable: executable, profile: profile, localPort: port
    )
    let process = try start(command)
    sessions[profile.id] = Session(processes: [process], cleanup: nil)
    do {
      try await waitUntilListening(port: port, process: process)
      return TransportEndpoint(host: "127.0.0.1", port: port)
    } catch {
      await close(profileID: profile.id)
      throw error
    }
  }

  private func openKubernetes(_ profile: ConnectionProfile) async throws -> TransportEndpoint {
    guard let configuration = profile.kubernetes else {
      throw SolnariDatabaseError.incompleteConnection
    }
    let executable =
      try executables.kubectl
      ?? ExecutableResolver.resolve(name: "kubectl", environmentKey: "SOLNARI_KUBECTL")
    let localPort = try Self.availablePort()
    switch configuration.effectiveConnectionMode {
    case .existingResource:
      return try await openExistingKubernetesResource(
        profileID: profile.id,
        configuration: configuration,
        executable: executable,
        localPort: localPort
      )
    case .temporaryRelay:
      return try await openTemporaryKubernetesRelay(
        profile: profile,
        configuration: configuration,
        executable: executable,
        localPort: localPort
      )
    }
  }

  private func openExistingKubernetesResource(
    profileID: UUID,
    configuration: KubernetesConfiguration,
    executable: String,
    localPort: Int
  ) async throws -> TransportEndpoint {
    let forward = try start(
      TransportCommandBuilder.kubernetesExistingResourceForward(
        executable: executable,
        configuration: configuration,
        localPort: localPort
      ))
    sessions[profileID] = Session(processes: [forward], cleanup: nil)
    do {
      try await waitUntilListening(port: localPort, process: forward)
      return TransportEndpoint(host: "127.0.0.1", port: localPort)
    } catch {
      await close(profileID: profileID)
      throw error
    }
  }

  private func openTemporaryKubernetesRelay(
    profile: ConnectionProfile,
    configuration: KubernetesConfiguration,
    executable: String,
    localPort: Int
  ) async throws -> TransportEndpoint {
    let relayPort = profile.engine == .mysql ? 13_306 : 15_432
    let relayName = "solnari-relay-\(profile.id.uuidString.lowercased().prefix(8))"
    let cleanup = TransportCommandBuilder.kubernetesDelete(
      executable: executable, configuration: configuration, relayName: relayName
    )

    do {
      _ = try? await run(cleanup)
      try await requireSuccess(
        TransportCommandBuilder.kubernetesRun(
          executable: executable,
          profile: profile,
          relayName: relayName,
          relayPort: relayPort
        ))
      sessions[profile.id] = Session(processes: [], cleanup: cleanup)
      try await requireSuccess(
        TransportCommandBuilder.kubernetesWait(
          executable: executable, configuration: configuration, relayName: relayName
        ))
      let forward = try start(
        TransportCommandBuilder.kubernetesForward(
          executable: executable,
          configuration: configuration,
          relayName: relayName,
          localPort: localPort,
          relayPort: relayPort
        ))
      sessions[profile.id]?.processes.append(forward)
      try await waitUntilListening(port: localPort, process: forward)
      return TransportEndpoint(host: "127.0.0.1", port: localPort)
    } catch {
      if sessions[profile.id] == nil {
        _ = try? await run(cleanup)
      } else {
        await close(profileID: profile.id)
      }
      throw error
    }
  }

  private func start(_ command: TransportCommand) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
  }

  private func run(_ command: TransportCommand) async throws -> (status: Int32, error: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardOutput = output
    process.standardError = output
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data.prefix(8_192), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: (process.terminationStatus, message))
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func requireSuccess(_ command: TransportCommand) async throws {
    let result = try await run(command)
    guard result.status == 0 else {
      throw SolnariDatabaseError.transportFailed(
        result.error.isEmpty
          ? "\(command.executable) exited with status \(result.status)." : result.error
      )
    }
  }

  private func waitUntilListening(port: Int, process: Process) async throws {
    for _ in 0..<150 {
      if Self.isPortInUse(port) { return }
      if !process.isRunning {
        let pipe = process.standardError as? Pipe
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let message = String(decoding: data.prefix(8_192), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        throw SolnariDatabaseError.transportFailed(
          message.isEmpty ? "The helper process exited unexpectedly." : message
        )
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw SolnariDatabaseError.transportTimedOut
  }

  private static func availablePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw SolnariDatabaseError.transportFailed("Cannot create socket.")
    }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard status == 0 else {
      throw SolnariDatabaseError.transportFailed("Cannot reserve local port.")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameStatus = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameStatus == 0 else {
      throw SolnariDatabaseError.transportFailed("Cannot read local port.")
    }
    return Int(UInt16(bigEndian: address.sin_port))
  }

  private static func isPortInUse(_ port: Int) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return status != 0 && errno == EADDRINUSE
  }
}

enum ExecutableResolver {
  static func resolve(name: String, environmentKey: String) throws -> String {
    let environment = ProcessInfo.processInfo.environment
    if let configured = environment[environmentKey],
      FileManager.default.isExecutableFile(atPath: configured)
    {
      return configured
    }
    let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let bundledHelpers = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true).path
    let directories =
      pathDirectories + [
        bundledHelpers,
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/google-cloud-sdk/bin",
        "/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin",
        "/usr/local/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin",
      ]
    if let path =
      directories
      .map({ URL(fileURLWithPath: $0).appendingPathComponent(name).path })
      .first(where: FileManager.default.isExecutableFile(atPath:))
    {
      return path
    }
    if let path = resolveFromLoginShell(name: name) {
      return path
    }
    throw SolnariDatabaseError.missingExecutable(name)
  }

  private static func resolveFromLoginShell(name: String) -> String? {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
    guard name.unicodeScalars.allSatisfy(allowedCharacters.contains) else { return nil }

    let process = Process()
    let output = Pipe()
    let completion = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lic", "command -v -- \(name)"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in completion.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    guard completion.wait(timeout: .now() + 3) == .success else {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }

    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return result.split(whereSeparator: \Character.isNewline)
      .map(String.init)
      .last(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
  }
}
