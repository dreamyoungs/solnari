import AppKit
import Foundation

/// Uses Codex's own configuration writer, including the executable bundled in its desktop app.
enum MCPRegistration {
  @MainActor
  static func executableURL() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let applications = [
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
      URL(fileURLWithPath: "/Applications/Codex.app"),
      URL(fileURLWithPath: "/Applications/ChatGPT.app"),
      home.appendingPathComponent("Applications/Codex.app"),
      home.appendingPathComponent("Applications/ChatGPT.app"),
    ].compactMap { $0 }
    let bundled = applications.flatMap { app in
      [
        "Contents/Resources/codex",
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
      ]
      .map { app.appendingPathComponent($0).path }
    }
    let candidates =
      [ProcessInfo.processInfo.environment["SOLNARI_CODEX"]].compactMap { $0 }
      + bundled + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    return candidates.first {
      FileManager.default.isExecutableFile(atPath: $0)
    }.map { URL(fileURLWithPath: $0) }
  }

  static func install(executable: URL, serverArguments: [String]) async throws {
    try await Task.detached {
      let process = Process()
      process.executableURL = executable
      process.arguments = ["mcp", "add", "solnari", "--"] + serverArguments
      // Register in the user's configuration, never in the app's isolated assistant home.
      process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      let deadline = ContinuousClock.now + .seconds(15)
      while process.isRunning {
        if ContinuousClock.now >= deadline || Task.isCancelled {
          process.terminate()
          throw RegistrationError.failed
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard process.terminationStatus == 0 else { throw RegistrationError.failed }
    }.value
  }

  static var antigravityConfigURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".gemini/config/mcp_config.json")
  }

  static func installInAntigravity(
    serverArguments: [String],
    configURL: URL? = nil
  ) async throws {
    guard let command = serverArguments.first else { throw RegistrationError.failed }
    let arguments = Array(serverArguments.dropFirst())
    let targetURL = configURL ?? antigravityConfigURL
    try await Task.detached {
      let directory = targetURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      var root: [String: Any] = [:]
      if FileManager.default.fileExists(atPath: targetURL.path) {
        let existing = try Data(contentsOf: targetURL)
        let trimmed = String(data: existing, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
          guard
            let parsed = try JSONSerialization.jsonObject(with: existing) as? [String: Any]
          else {
            throw RegistrationError.failed
          }
          root = parsed
        }
      }

      var servers: [String: Any]
      if let existingServers = root["mcpServers"] {
        guard let dictionary = existingServers as? [String: Any] else {
          throw RegistrationError.failed
        }
        servers = dictionary
      } else {
        servers = [:]
      }

      servers["solnari"] = [
        "command": command,
        "args": arguments,
      ]
      root["mcpServers"] = servers

      var serialized = try JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
      serialized.append(0x0A)
      try serialized.write(to: targetURL, options: .atomic)
    }.value
  }

  enum RegistrationError: Error {
    case failed
  }
}
