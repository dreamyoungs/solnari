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
}
