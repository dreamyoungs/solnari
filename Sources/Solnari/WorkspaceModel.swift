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
  @Published private(set) var editingConnectionID: UUID?
  @Published var selectedResultTab = "Results"
  @Published var presentedError: String?
  @Published var presentedSchemaObject: SchemaObject?
  @Published private(set) var areConnectionOperationsSuspended = false

  private let backend: DatabaseBackend
  private let profileStore: ConnectionProfileStore
  private let passwordStore: LocalEncryptedPasswordStore
  private var activeSuspensionCleanups = 0
  private var resumeRequestedAfterCleanup = false

  init(
    backend: DatabaseBackend = DatabaseBackend(),
    profileStore: ConnectionProfileStore = ConnectionProfileStore(),
    passwordStore: LocalEncryptedPasswordStore = LocalEncryptedPasswordStore()
  ) {
    self.backend = backend
    self.profileStore = profileStore
    self.passwordStore = passwordStore

    let storedConnections: [ConnectionProfile]
    let profileLoadError: String?
    do {
      storedConnections = try profileStore.load()
      profileLoadError = nil
    } catch {
      storedConnections = []
      profileLoadError = error.localizedDescription
    }
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
    presentedError = profileLoadError
  }

  var selectedConnection: ConnectionProfile? {
    connections.first { $0.id == selectedConnectionID }
  }

  var editingConnection: ConnectionProfile? {
    guard let editingConnectionID else { return nil }
    return connections.first { $0.id == editingConnectionID }
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

  func presentSchemaObject(_ object: SchemaObject) {
    presentedSchemaObject = object
  }

  func dismissSchemaObject() {
    presentedSchemaObject = nil
  }

  func loadSchemaObjectDetails(_ object: SchemaObject) async throws -> SchemaObjectDetails {
    guard let profileID = selectedConnectionID else {
      throw SolnariDatabaseError.missingConnection
    }
    if connections.first(where: { $0.id == profileID })?.status != .connected {
      await connect(profileID: profileID)
    }
    guard connections.first(where: { $0.id == profileID })?.status == .connected else {
      throw SolnariDatabaseError.notConnected
    }
    return try await backend.loadSchemaObjectDetails(profileID: profileID, object: object)
  }

  func generateSelect(for object: SchemaObject) {
    guard let engine = selectedConnection?.engine else { return }
    let sql = SQLObjectQueryBuilder.selectAll(from: object, engine: engine)
    let tab = EditorTab(title: object.name, sql: sql)
    editorTabs.append(tab)
    selectedTabID = tab.id
  }

  func openData(for object: SchemaObject) async {
    generateSelect(for: object)
    await runCurrentQuery()
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

  func beginNewConnection() {
    editingConnectionID = nil
    showNewConnection = true
  }

  func beginEditingConnection(_ profileID: UUID) {
    guard connections.contains(where: { $0.id == profileID }) else { return }
    editingConnectionID = profileID
    showNewConnection = true
  }

  func finishConnectionPresentation() {
    editingConnectionID = nil
  }

  func testConnection(
    _ draft: ConnectionDraft,
    replacing profileID: UUID? = nil
  ) async throws -> ConnectionMetadata {
    guard !areConnectionOperationsSuspended else { throw SolnariDatabaseError.notConnected }
    let profile = try draft.makeProfile()
    let password = try resolvedPassword(for: draft, replacing: profileID)
    return try await backend.testConnection(profile: profile, password: password)
  }

  func saveAndConnect(
    _ draft: ConnectionDraft,
    replacing profileID: UUID? = nil
  ) async throws {
    guard !areConnectionOperationsSuspended else { throw SolnariDatabaseError.notConnected }
    let originalConnections = connections
    let originalSelection = selectedConnectionID
    let originalSchema = schemaObjects
    let existingPassword = try profileID.flatMap { try passwordStore.password(for: $0) }
    let password = try resolvedPassword(for: draft, replacing: profileID)
    var profile = try draft.makeProfile(id: profileID ?? UUID())

    do {
      let metadata = try await backend.connect(profile: profile, password: password)
      guard !areConnectionOperationsSuspended else {
        throw SolnariDatabaseError.notConnected
      }
      let loadedSchema = try await backend.loadSchema(profileID: profile.id)
      if draft.transport == .cloudSQL && draft.useIAM {
        try passwordStore.delete(for: profile.id)
      } else if !draft.password.isEmpty || profileID == nil {
        try passwordStore.save(draft.connectionPassword, for: profile.id)
      }
      apply(metadata, to: &profile)
      profile.status = .connected
      if let index = connections.firstIndex(where: { $0.id == profile.id }) {
        connections[index] = profile
      } else {
        connections.insert(profile, at: 0)
      }
      selectedConnectionID = profile.id
      try profileStore.save(connections)
      schemaObjects = loadedSchema
    } catch {
      await backend.disconnect(profileID: profile.id)
      connections = originalConnections
      if let restoredIndex = connections.firstIndex(where: { $0.id == profile.id }) {
        connections[restoredIndex].status = .disconnected
      }
      selectedConnectionID = originalSelection
      schemaObjects = originalSelection == profile.id ? [] : originalSchema
      if let existingPassword {
        try? passwordStore.save(existingPassword, for: profile.id)
      } else {
        try? passwordStore.delete(for: profile.id)
      }
      try? profileStore.save(connections)
      throw error
    }
  }

  private func resolvedPassword(
    for draft: ConnectionDraft,
    replacing profileID: UUID?
  ) throws -> String {
    if draft.transport == .cloudSQL && draft.useIAM { return "" }
    if !draft.password.isEmpty { return draft.password }
    guard let profileID else { return "" }
    return try passwordStore.password(for: profileID) ?? ""
  }

  func activateSelectedConnection() async {
    guard !areConnectionOperationsSuspended else { return }
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
    guard !areConnectionOperationsSuspended, !isConnecting,
      let index = connections.firstIndex(where: { $0.id == profileID })
    else {
      return
    }
    isConnecting = true
    connections[index].status = .connecting

    do {
      let profile = connections[index]
      let password = try passwordStore.password(for: profileID) ?? ""
      let metadata = try await backend.connect(profile: profile, password: password)
      guard !areConnectionOperationsSuspended else {
        await backend.disconnect(profileID: profileID)
        isConnecting = false
        return
      }
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
        connections[failedIndex].status =
          areConnectionOperationsSuspended ? .disconnected : .failed
      }
      if selectedConnectionID == profileID { schemaObjects = [] }
      if !areConnectionOperationsSuspended {
        presentedError = error.localizedDescription
      }
    }
    isConnecting = false
  }

  func refreshSchema() async {
    guard !areConnectionOperationsSuspended, let profileID = selectedConnectionID else { return }
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
    guard !areConnectionOperationsSuspended, !isRunning, let profileID = selectedConnectionID,
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
      if areConnectionOperationsSuspended {
        executionMessage = "No results"
      } else {
        executionMessage = "Query failed"
        presentedError = error.localizedDescription
      }
    }
    isRunning = false
  }

  func suspendConnections() async {
    resumeRequestedAfterCleanup = false
    activeSuspensionCleanups += 1
    areConnectionOperationsSuspended = true
    isConnecting = false
    isRunning = false
    schemaObjects = []
    executionMessage = "No results"
    for index in connections.indices {
      connections[index].status = .disconnected
    }
    await backend.disconnectAll()
    for index in connections.indices {
      connections[index].status = .disconnected
    }
    try? profileStore.save(connections)
    activeSuspensionCleanups -= 1
    if activeSuspensionCleanups == 0, resumeRequestedAfterCleanup {
      resumeRequestedAfterCleanup = false
      areConnectionOperationsSuspended = false
    }
  }

  func resumeConnectionOperations() {
    if activeSuspensionCleanups > 0 {
      resumeRequestedAfterCleanup = true
    } else {
      areConnectionOperationsSuspended = false
    }
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
