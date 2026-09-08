import Foundation

indirect enum CodexJSON: Codable, Sendable, Equatable {
  case object([String: CodexJSON])
  case array([CodexJSON])
  case string(String)
  case number(Int)
  case decimal(Double)
  case bool(Bool)
  case null
  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let v = try? value.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? value.decode(Int.self) {
      self = .number(v)
    } else if let v = try? value.decode(Double.self) {
      self = .decimal(v)
    } else if let v = try? value.decode(String.self) {
      self = .string(v)
    } else if let v = try? value.decode([CodexJSON].self) {
      self = .array(v)
    } else {
      self = .object(try value.decode([String: CodexJSON].self))
    }
  }
  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .object(let v): try value.encode(v)
    case .array(let v): try value.encode(v)
    case .string(let v): try value.encode(v)
    case .number(let v): try value.encode(v)
    case .decimal(let v): try value.encode(v)
    case .bool(let v): try value.encode(v)
    case .null: try value.encodeNil()
    }
  }
  subscript(_ key: String) -> CodexJSON? {
    if case .object(let v) = self { return v[key] }
    return nil
  }
  var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  var array: [CodexJSON]? {
    if case .array(let v) = self { return v }
    return nil
  }
}

enum CodexAssistantError: Error, LocalizedError, Equatable {
  case unavailable, unsupportedVersion, terminated, invalidResponse, privacy, requestFailed,
    timeout, signInRequired, sensitiveContext
  var errorDescription: String? {
    switch self {
    case .unavailable: "Codex CLI was not found. Install Codex CLI or the Codex desktop app."
    case .unsupportedVersion:
      "This Codex CLI version has not been verified. This integration requires Codex CLI 0.153.x."
    case .terminated: "Codex stopped. Reconnect to start a new temporary conversation."
    case .invalidResponse: "Codex returned an invalid response. Start a new conversation."
    case .privacy:
      "Codex could not verify a temporary, restricted session. No database context was sent."
    case .requestFailed: "Codex could not complete the request. Check your account and try again."
    case .timeout: "Codex did not respond in time. Reconnect and try again."
    case .signInRequired: "Sign in to ChatGPT to use the SQL assistant."
    case .sensitiveContext:
      "The request may contain credentials, a connection address or sensitive fields. Remove them before sending."
    }
  }
}

enum CodexSessionPolicy {
  static let disabledFeatures = [
    "shell_tool", "unified_exec", "shell_snapshot", "shell_snapshot_v2", "code_mode",
    "code_mode_host", "code_mode_only",
    "js_repl", "js_repl_tools_only", "apps", "connectors", "plugins", "plugin_hooks", "hooks",
    "codex_hooks", "multi_agent", "multi_agent_v2",
    "collab", "computer_use", "browser_use", "browser_use_external", "in_app_browser", "view_image",
    "image_generation", "imagegenext",
    "memories", "memory_tool", "skill_search", "skill_mcp_dependency_install", "tool_suggest",
    "tool_search", "search_tool", "workspace_dependencies",
    "request_permissions_tool", "request_permissions", "remote_control", "remote_plugin",
    "external_agent_memory_import",
  ]
  static var configuration: [String: CodexJSON] {
    var result: [String: CodexJSON] = [
      "history.persistence": .string("none"), "analytics.enabled": .bool(false),
      "feedback.enabled": .bool(false), "otel.log_user_prompt": .bool(false),
      "otel.exporter": .string("none"), "otel.trace_exporter": .string("none"),
      "web_search": .string("disabled"), "project_root_markers": .array([]),
      "project_doc_max_bytes": .number(0),
      "memories.generate_memories": .bool(false), "memories.use_memories": .bool(false),
      "features.skip_host_skill_discovery": .bool(true),
      "cli_auth_credentials_store": .string("keyring"),
      "model_provider": .string("openai"), "approval_policy": .string("never"),
      "sandbox_mode": .string("read-only"),
    ]
    for name in disabledFeatures { result["features.\(name)"] = .bool(false) }
    return result
  }
  static func validateThread(_ response: CodexJSON) throws -> String {
    guard let thread = response["thread"], thread["ephemeral"] == .bool(true),
      thread["path"] == .null,
      let id = thread["id"]?.string, !id.isEmpty,
      response["sandbox"]?["type"] == .string("readOnly"),
      response["sandbox"]?["networkAccess"] == .bool(false),
      response["approvalPolicy"] == .string("never"),
      response["instructionSources"] == .array([])
    else { throw CodexAssistantError.privacy }
    return id
  }
  static func supports(version: String) -> Bool {
    version.range(
      of: #"(?:codex-cli |solnari_sql_assistant/)?0\.153\.\d+(?:\s|$)"#, options: .regularExpression
    ) != nil
  }

  static func validateConfiguration(_ response: CodexJSON) throws {
    guard let config = response["config"] else { throw CodexAssistantError.privacy }
    for (key, expected) in configuration {
      let actual = key.split(separator: ".").reduce(Optional(config)) { $0?[String($1)] }
      guard actual == expected else { throw CodexAssistantError.privacy }
    }
    for key in ["mcp_servers", "plugins"] {
      guard config[key] == nil || config[key] == .object([:]) else {
        throw CodexAssistantError.privacy
      }
    }
  }
}
