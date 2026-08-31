import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published var connections: [ConnectionProfile]
  @Published var selectedConnectionID: UUID?
  @Published var schemaObjects: [SchemaObject] = []
  @Published var editorTabs: [EditorTab]
  @Published var selectedTabID: UUID?
  @Published var queryTable: QueryTableData = .empty
  @Published var assistantMessages: [AssistantMessage]
  @Published var assistantDraft = ""
  @Published var isAssistantVisible = true
  @Published var isRunning = false
  @Published var isConnecting = false
  @Published var executionMessage = "No results"
  @Published var showNewConnection = false
  @Published var selectedResultTab = "Results"
  @Published var presentedError: String?

  private let backend: DatabaseBackend
  private let profileStore: ConnectionProfileStore
  private let passwordStore: KeychainPasswordStore

  init(
    backend: DatabaseBackend = DatabaseBackend(),
    profileStore: ConnectionProfileStore = ConnectionProfileStore(),
    passwordStore: KeychainPasswordStore = KeychainPasswordStore()
  ) {
    self.backend = backend
    self.profileStore = profileStore
    self.passwordStore = passwordStore

    let storedConnections = profileStore.load()
    connections = storedConnections
    selectedConnectionID = storedConnections.first?.id

    let query = EditorTab(
      title: "Query 1",
      sql: """
        SELECT
          current_database() AS database,
          current_user AS user,
          now() AS server_time;
        """
    )
    editorTabs = [query]
    selectedTabID = query.id
    assistantMessages = [
      AssistantMessage(
        role: .assistant,
        text: "I’ve read the schema. I can explain queries or suggest safer and faster SQL.",
        sql: nil
      )
    ]
  }

  var selectedConnection: ConnectionProfile? {
    connections.first { $0.id == selectedConnectionID }
  }

  var selectedTab: EditorTab? {
    editorTabs.first { $0.id == selectedTabID }
  }

  func sqlBinding(for tabID: UUID) -> Binding<String> {
    Binding(
      get: { [weak self] in
        self?.editorTabs.first { $0.id == tabID }?.sql ?? ""
      },
      set: { [weak self] newValue in
        guard let self, let index = self.editorTabs.firstIndex(where: { $0.id == tabID }) else {
          return
        }
        self.editorTabs[index].sql = newValue
        self.editorTabs[index].isModified = true
      }
    )
  }

  func newQueryTab() {
    let number = editorTabs.count + 1
    let tab = EditorTab(title: "Query \(number)", sql: "SELECT ")
    editorTabs.append(tab)
    selectedTabID = tab.id
  }

  func closeTab(_ tabID: UUID) {
    guard editorTabs.count > 1, let index = editorTabs.firstIndex(where: { $0.id == tabID }) else {
      return
    }
    editorTabs.remove(at: index)
    if selectedTabID == tabID {
      selectedTabID = editorTabs[min(index, editorTabs.count - 1)].id
    }
  }

  func testConnection(_ draft: ConnectionDraft) async throws -> ConnectionMetadata {
    let profile = try draft.makeProfile()
    return try await backend.testConnection(profile: profile, password: draft.password)
  }

  func saveAndConnect(_ draft: ConnectionDraft) async throws {
    var profile = try draft.makeProfile()
    let metadata = try await backend.connect(profile: profile, password: draft.password)

    do {
      let loadedSchema = try await backend.loadSchema(profileID: profile.id)
      try passwordStore.save(draft.password, for: profile.id)
      apply(metadata, to: &profile)
      profile.status = .connected
      connections.insert(profile, at: 0)
      selectedConnectionID = profile.id
      try profileStore.save(connections)
      schemaObjects = loadedSchema
    } catch {
      await backend.disconnect(profileID: profile.id)
      connections.removeAll { $0.id == profile.id }
      try? passwordStore.delete(for: profile.id)
      try? profileStore.save(connections)
      throw error
    }
  }

  func activateSelectedConnection() async {
    guard let selectedConnectionID else {
      schemaObjects = []
      return
    }
    guard connections.first(where: { $0.id == selectedConnectionID })?.status != .connected else {
      return
    }
    await connect(profileID: selectedConnectionID)
  }

  func connect(profileID: UUID) async {
    guard !isConnecting, let index = connections.firstIndex(where: { $0.id == profileID }) else {
      return
    }
    isConnecting = true
    connections[index].status = .connecting

    do {
      let profile = connections[index]
      let password = try passwordStore.password(for: profileID) ?? ""
      let metadata = try await backend.connect(profile: profile, password: password)
      guard let refreshedIndex = connections.firstIndex(where: { $0.id == profileID }) else {
        throw SolnariDatabaseError.missingConnection
      }
      apply(metadata, to: &connections[refreshedIndex])
      connections[refreshedIndex].status = .connected
      if selectedConnectionID == profileID {
        schemaObjects = try await backend.loadSchema(profileID: profileID)
      }
      try profileStore.save(connections)
    } catch {
      if let failedIndex = connections.firstIndex(where: { $0.id == profileID }) {
        connections[failedIndex].status = .failed
      }
      if selectedConnectionID == profileID { schemaObjects = [] }
      presentedError = error.localizedDescription
    }
    isConnecting = false
  }

  func refreshSchema() async {
    guard let profileID = selectedConnectionID else { return }
    do {
      schemaObjects = try await backend.loadSchema(profileID: profileID)
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func removeConnection(_ profileID: UUID) async {
    await backend.disconnect(profileID: profileID)
    do {
      try passwordStore.delete(for: profileID)
    } catch {
      presentedError = error.localizedDescription
    }
    connections.removeAll { $0.id == profileID }
    if selectedConnectionID == profileID {
      selectedConnectionID = connections.first?.id
      schemaObjects = []
    }
    do {
      try profileStore.save(connections)
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func runCurrentQuery() async {
    guard !isRunning, let profileID = selectedConnectionID,
      let sql = selectedTab?.sql.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty
    else { return }

    if connections.first(where: { $0.id == profileID })?.status != .connected {
      await connect(profileID: profileID)
      guard connections.first(where: { $0.id == profileID })?.status == .connected else { return }
    }

    isRunning = true
    executionMessage = "Running query…"
    do {
      let result = try await backend.execute(profileID: profileID, sql: sql)
      queryTable = result.table
      executionMessage =
        result.table.rows.isEmpty
        ? "Query completed · \(result.durationMilliseconds) ms"
        : "\(result.table.rows.count) rows · \(result.durationMilliseconds) ms"
      if sql.localizedCaseInsensitiveContains("CREATE ")
        || sql.localizedCaseInsensitiveContains("ALTER ")
        || sql.localizedCaseInsensitiveContains("DROP ")
      {
        await refreshSchema()
      }
    } catch {
      executionMessage = "Query failed"
      presentedError = error.localizedDescription
    }
    isRunning = false
  }

  func clearResults() {
    queryTable = .empty
    executionMessage = "No results"
  }

  func formatCurrentSQL() {
    guard let selectedTabID,
      let index = editorTabs.firstIndex(where: { $0.id == selectedTabID })
    else { return }
    var sql = editorTabs[index].sql
    for keyword in [
      "select", "from", "left join", "on", "where", "group by", "order by", "limit", "as",
    ] {
      sql = sql.replacingOccurrences(
        of: keyword, with: keyword.uppercased(), options: .caseInsensitive)
    }
    editorTabs[index].sql = sql
    editorTabs[index].isModified = true
  }

  func useSQL(_ sql: String) {
    guard let selectedTabID,
      let index = editorTabs.firstIndex(where: { $0.id == selectedTabID })
    else { return }
    editorTabs[index].sql = sql
    editorTabs[index].isModified = true
  }

  func sendAssistantMessage() {
    let trimmed = assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    assistantMessages.append(AssistantMessage(role: .user, text: trimmed, sql: nil))
    assistantDraft = ""
    assistantMessages.append(
      AssistantMessage(
        role: .assistant,
        text:
          "I created a read-only query using only the selected schema. Review the SQL before running it.",
        sql: "SELECT current_database(), current_user, now();"
      )
    )
  }

  private func apply(_ metadata: ConnectionMetadata, to profile: inout ConnectionProfile) {
    profile.database = metadata.database
    profile.latency = metadata.latencyMilliseconds
    profile.serverVersion = metadata.serverVersion
    profile.serverEncoding = metadata.serverEncoding
    profile.serverTimeZone = metadata.serverTimeZone
  }
}
