import Foundation
import Testing

@testable import Solnari

struct MCPRegistrationTests {
  @Test("등록은 공백이 있는 경로를 그대로 전달하고 사용자 설정 위치를 보존한다")
  func passesArgumentsWithoutShellExpansion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCP Register \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake codex")
    let output = directory.appendingPathComponent("arguments.json")
    // JSON records argument boundaries without interpreting shell metacharacters.
    let script = """
      #!/usr/bin/python3
      import json, os, sys
      with open(os.path.join(os.path.dirname(__file__), 'arguments.json'), 'w') as f:
          json.dump({'args': sys.argv[1:], 'cwd': os.getcwd()}, f)
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let arguments = [
      "/Applications/Solnari App/Node/bin/node", "--require", "literal $(value).cjs", "server.cjs",
    ]
    try await MCPRegistration.install(executable: executable, serverArguments: arguments)
    struct Invocation: Decodable {
      let args: [String]
      let cwd: String
    }
    let invocation = try JSONDecoder().decode(Invocation.self, from: Data(contentsOf: output))
    #expect(invocation.args == ["mcp", "add", "solnari", "--"] + arguments)
    #expect(invocation.cwd == FileManager.default.homeDirectoryForCurrentUser.path)
  }

  @Test("등록 명령 실패를 성공으로 표시하지 않는다")
  func reportsFailure() async throws {
    await #expect(throws: MCPRegistration.RegistrationError.self) {
      try await MCPRegistration.install(
        executable: URL(fileURLWithPath: "/usr/bin/false"), serverArguments: [])
    }
  }

  @Test("Antigravity 설정 파일이 없으면 디렉터리를 만들고 solnari MCP를 등록한다")
  func createsAntigravityConfigWhenMissing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Antigravity MCP \(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config/mcp_config.json")
    let arguments = ["/Applications/Solnari.app/Node/bin/node", "--require", "guard.cjs", "mcp.cjs"]

    try await MCPRegistration.installInAntigravity(serverArguments: arguments, configURL: configURL)

    let data = try Data(contentsOf: configURL)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let servers = json?["mcpServers"] as? [String: Any]
    let solnari = servers?["solnari"] as? [String: Any]
    #expect(solnari?["command"] as? String == arguments[0])
    #expect(solnari?["args"] as? [String] == Array(arguments.dropFirst()))
  }

  @Test("Antigravity 등록 시 기존 다른 MCP 서버와 설정을 보존한다")
  func preservesExistingAntigravityServers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Antigravity MCP Preserve \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("mcp_config.json")
    let initial = """
      {
        "mcpServers": {
          "figcraft": {
            "command": "/opt/homebrew/bin/figcraft-cli",
            "args": ["mcp"]
          }
        },
        "customFlag": true
      }
      """
    try initial.write(to: configURL, atomically: true, encoding: .utf8)

    let arguments = ["/app/node", "--require", "guard.cjs", "mcp.cjs"]
    try await MCPRegistration.installInAntigravity(serverArguments: arguments, configURL: configURL)

    let data = try Data(contentsOf: configURL)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["customFlag"] as? Bool == true)
    let servers = json?["mcpServers"] as? [String: Any]
    let figcraft = servers?["figcraft"] as? [String: Any]
    let solnari = servers?["solnari"] as? [String: Any]
    #expect(figcraft?["command"] as? String == "/opt/homebrew/bin/figcraft-cli")
    #expect(solnari?["command"] as? String == "/app/node")
    #expect(solnari?["args"] as? [String] == ["--require", "guard.cjs", "mcp.cjs"])
  }

  @Test("Antigravity 설정 파일이 손상된 JSON이면 덮어쓰지 않고 실패한다")
  func rejectsInvalidAntigravityJSON() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Antigravity MCP Invalid \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("mcp_config.json")
    try "{invalid json".write(to: configURL, atomically: true, encoding: .utf8)

    await #expect(throws: Error.self) {
      try await MCPRegistration.installInAntigravity(
        serverArguments: ["/app/node", "mcp.cjs"],
        configURL: configURL
      )
    }
    #expect(try String(contentsOf: configURL, encoding: .utf8) == "{invalid json")
  }
}
