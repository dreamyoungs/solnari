// 실제 네트워크 대신 JSONL 수명주기와 잘못된 서버 응답을 재현하는 테스트 실행 파일입니다.
import Foundation
import Security

let home = ProcessInfo.processInfo.environment["CODEX_HOME"]!
let scenario = URL(fileURLWithPath: home).lastPathComponent
if scenario == "exit" { exit(0) }
let forbidden = URL(fileURLWithPath: home).deletingLastPathComponent().appendingPathComponent(
  "blocked-secret")
if (try? Data(contentsOf: forbidden)) != nil { exit(20) }
if (try? Data("blocked".utf8).write(
  to: forbidden.deletingLastPathComponent().appendingPathComponent("blocked-write"))) != nil
{
  exit(21)
}
let forbiddenProcess = Process()
forbiddenProcess.executableURL = URL(fileURLWithPath: "/bin/echo")
forbiddenProcess.arguments = ["should-not-execute"]
forbiddenProcess.standardOutput = FileHandle.nullDevice
if (try? forbiddenProcess.run()) != nil { exit(22) }
// 실제 인증 항목 대신 매 실행마다 고유한 테스트 항목만 저장·조회·삭제합니다.
if scenario == "keychain" {
  SecKeychainSetUserInteractionAllowed(false)
  let service = "com.dreamyoungs.solnari.test.\(UUID().uuidString)"
  let account = "synthetic-login"
  let value = Data("synthetic-test-value".utf8)
  var item: SecKeychainItem?
  let saved = service.withCString { serviceBytes in
    account.withCString { accountBytes in
      value.withUnsafeBytes { bytes in
        SecKeychainAddGenericPassword(
          nil, UInt32(service.utf8.count), serviceBytes, UInt32(account.utf8.count), accountBytes,
          UInt32(value.count), bytes.baseAddress!, &item)
      }
    }
  }
  guard saved == errSecSuccess, let item else { exit(23) }
  var length: UInt32 = 0
  var bytes: UnsafeMutableRawPointer?
  let loaded = SecKeychainItemCopyContent(item, nil, nil, &length, &bytes)
  let matches =
    loaded == errSecSuccess && bytes.map { Data(bytes: $0, count: Int(length)) } == value
  if let bytes { SecKeychainItemFreeContent(nil, bytes) }
  let deleted = SecKeychainItemDelete(item)
  guard matches, deleted == errSecSuccess else { exit(24) }
}
var config: [String: Any] = [:]
func inserting(_ value: Any, path: [String], into source: [String: Any]) -> [String: Any] {
  var result = source
  guard let first = path.first else { return source }
  if path.count == 1 {
    result[first] = value
  } else {
    result[first] = inserting(
      value, path: Array(path.dropFirst()), into: result[first] as? [String: Any] ?? [:])
  }
  return result
}
for argument in CommandLine.arguments where argument.contains("=") {
  let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
  if let data = parts.last?.data(using: .utf8),
    let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
  {
    config = inserting(value, path: parts[0].split(separator: ".").map(String.init), into: config)
  }
}
func emit(_ object: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
  FileHandle.standardOutput.write(data + Data([10]))
}
func notify(_ method: String, _ params: [String: Any]) {
  emit(["method": method, "params": params])
}
while let line = readLine() {
  guard let data = line.data(using: .utf8),
    let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let method = request["method"] as? String
  else { continue }
  let id = request["id"] ?? NSNull()
  let params = request["params"] as? [String: Any] ?? [:]
  func reply(_ result: [String: Any]) { emit(["id": id, "result": result]) }
  switch method {
  case "initialize": reply(["userAgent": "solnari_sql_assistant/0.153.4 (test)"])
  case "initialized": break
  case "config/read": reply(["config": config])
  case "account/read":
    reply(["account": ["type": "chatgpt", "email": NSNull(), "planType": "plus"]])
  case "thread/start":
    guard params["ephemeral"] as? Bool == true else { exit(10) }
    reply([
      "thread": [
        "id": "thread", "ephemeral": scenario != "persistent",
        "path": scenario == "path" ? "/forbidden/path" as Any : NSNull(),
      ], "sandbox": ["type": "readOnly", "networkAccess": false], "approvalPolicy": "never",
      "instructionSources": [],
    ])
  case "turn/start":
    try! Data("1".utf8).write(to: URL(fileURLWithPath: home).appendingPathComponent("turn-count"))
    reply(["turn": ["id": "turn", "status": "inProgress"]])
    if scenario == "malformed" {
      FileHandle.standardOutput.write(Data("{not json}\n".utf8))
      continue
    }
    if scenario == "hang" { continue }
    if scenario == "tool" {
      emit(["id": "tool", "method": "item/commandExecution/requestApproval", "params": [:]])
      continue
    }
    let response = #"{"explanation":"로컬 테스트","sql":"SELECT 1"}"#
    notify(
      "item/agentMessage/delta",
      ["threadId": "thread", "turnId": "turn", "itemId": "message", "delta": response])
    notify(
      "turn/completed",
      [
        "threadId": "thread",
        "turn": [
          "id": "turn", "status": scenario == "failure" ? "failed" : "completed",
          "error": ["message": "secret diagnostic must not escape"],
        ],
      ])
  case "turn/interrupt":
    try! Data("1".utf8).write(
      to: URL(fileURLWithPath: home).appendingPathComponent("interrupt-count"))
    reply([:])
    notify(
      "turn/completed", ["threadId": "thread", "turn": ["id": "turn", "status": "interrupted"]])
  default: emit(["id": id, "error": ["code": -32601, "message": "unsupported"]])
  }
}
