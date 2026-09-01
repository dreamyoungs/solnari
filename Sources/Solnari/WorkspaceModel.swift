import Foundation
import SwiftUI

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published var connections: [ConnectionProfile]
  @Published var selectedConnectionID: UUID?
  @Published private var connectionWorkspaces: [UUID: ConnectionWorkspace] = [:]
  @Published private var detachedWorkspace = ConnectionWorkspace()
  @Published private(set) var connectingProfileIDs: Set<UUID> = []
  @Published var assistantMessages: [AssistantMessage]
  @Published var assistantDraft = ""
  @Published var isAssistantVisible = true
  @Published var showNewConnection = false
  @Published private(set) var editingConnectionID: UUID?
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
    connectionWorkspaces = Dictionary(
      uniqueKeysWithValues: storedConnections.map { ($0.id, ConnectionWorkspace()) }
    )
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

  var schemaSnapshot: SchemaSnapshot {
    workspace(for: selectedConnectionID).schema
  }

  var schemaNames: [String] {
    schemaSnapshot.schemas
  }

  var schemaObjects: [SchemaObject] {
    schemaSnapshot.objects
  }

  var editorTabs: [EditorTab] {
    workspace(for: selectedConnectionID).editorTabs
  }

  var selectedTabID: UUID? {
    get { workspace(for: selectedConnectionID).selectedTabID }
    set { updateWorkspace(for: selectedConnectionID) { $0.selectedTabID = newValue } }
  }

  var queryTable: QueryTableData {
    workspace(for: selectedConnectionID).queryTable
  }

  var executionMessage: String {
    workspace(for: selectedConnectionID).executionMessage
  }

  var selectedResultTab: String {
    get { workspace(for: selectedConnectionID).selectedResultTab }
    set { updateWorkspace(for: selectedConnectionID) { $0.selectedResultTab = newValue } }
  }

  var isRunning: Bool {
    workspace(for: selectedConnectionID).isRunning
  }

  var isConnecting: Bool {
    selectedConnectionID.map(connectingProfileIDs.contains) ?? false
  }

  var editingConnection: ConnectionProfile? {
    guard let editingConnectionID else { return nil }
    return connections.first { $0.id == editingConnectionID }
  }

  var selectedTab: EditorTab? {
    editorTabs.first { $0.id == selectedTabID }
  }

  func sqlBinding(for tabID: UUID) -> Binding<String> {
    let profileID = selectedConnectionID
    return Binding(
      get: { [weak self] in
        self?.workspace(for: profileID).editorTabs.first { $0.id == tabID }?.sql ?? ""
      },
      set: { [weak self] newValue in
        guard let self else { return }
        self.updateWorkspace(for: profileID) { workspace in
          guard let index = workspace.editorTabs.firstIndex(where: { $0.id == tabID }) else {
            return
          }
          workspace.editorTabs[index].sql = newValue
          workspace.editorTabs[index].isModified = true
        }
      }
    )
  }

  func newQueryTab() {
    let number = editorTabs.count + 1
    let tab = EditorTab(title: "Query \(number)", sql: "SELECT ")
    updateWorkspace(for: selectedConnectionID) {
      $0.editorTabs.append(tab)
      $0.selectedTabID = tab.id
    }
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
    updateWorkspace(for: selectedConnectionID) {
      $0.editorTabs.append(tab)
      $0.selectedTabID = tab.id
    }
  }

  func openData(for object: SchemaObject) async {
    generateSelect(for: object)
    await runCurrentQuery()
  }

  func closeTab(_ tabID: UUID) {
    guard editorTabs.count > 1, let index = editorTabs.firstIndex(where: { $0.id == tabID }) else {
      return
    }
    updateWorkspace(for: selectedConnectionID) { workspace in
      workspace.editorTabs.remove(at: index)
      if workspace.selectedTabID == tabID {
        let selectedIndex = min(index, workspace.editorTabs.count - 1)
        workspace.selectedTabID = workspace.editorTabs[selectedIndex].id
      }
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
    let profile = try draft.makeTestProfile()
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
    let originalWorkspaces = connectionWorkspaces
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
      if connectionWorkspaces[profile.id] == nil {
        connectionWorkspaces[profile.id] = ConnectionWorkspace()
      }
      updateWorkspace(for: profile.id) { $0.schema = loadedSchema }
      selectedConnectionID = profile.id
      try profileStore.save(connections)
    } catch {
      await backend.disconnect(profileID: profile.id)
      connections = originalConnections
      if let restoredIndex = connections.firstIndex(where: { $0.id == profile.id }) {
        connections[restoredIndex].status = .disconnected
      }
      selectedConnectionID = originalSelection
      connectionWorkspaces = originalWorkspaces
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
      presentedSchemaObject = nil
      return
    }
    ensureWorkspace(for: selectedConnectionID)
    presentedSchemaObject = nil
    guard connections.first(where: { $0.id == selectedConnectionID })?.status != .connected else {
      await refreshSchema(profileID: selectedConnectionID)
      return
    }
    await connect(profileID: selectedConnectionID)
  }

  func connect(profileID: UUID) async {
    guard !areConnectionOperationsSuspended, !connectingProfileIDs.contains(profileID),
      let index = connections.firstIndex(where: { $0.id == profileID })
    else {
      return
    }
    connectingProfileIDs.insert(profileID)
    ensureWorkspace(for: profileID)
    connections[index].status = .connecting

    do {
      let profile = connections[index]
      let password = try passwordStore.password(for: profileID) ?? ""
      let metadata = try await backend.connect(profile: profile, password: password)
      guard !areConnectionOperationsSuspended else {
        await backend.disconnect(profileID: profileID)
        connectingProfileIDs.remove(profileID)
        return
      }
      guard let refreshedIndex = connections.firstIndex(where: { $0.id == profileID }) else {
        throw SolnariDatabaseError.missingConnection
      }
      apply(metadata, to: &connections[refreshedIndex])
      connections[refreshedIndex].status = .connected
      let loadedSchema = try await backend.loadSchema(profileID: profileID)
      updateWorkspace(for: profileID) { $0.schema = loadedSchema }
      try profileStore.save(connections)
    } catch {
      if let failedIndex = connections.firstIndex(where: { $0.id == profileID }) {
        connections[failedIndex].status =
          areConnectionOperationsSuspended ? .disconnected : .failed
      }
      updateWorkspace(for: profileID) { $0.schema = .empty }
      if !areConnectionOperationsSuspended {
        presentedError = error.localizedDescription
      }
    }
    connectingProfileIDs.remove(profileID)
  }

  func refreshSchema(profileID: UUID? = nil) async {
    guard !areConnectionOperationsSuspended,
      let profileID = profileID ?? selectedConnectionID
    else {
      return
    }
    do {
      let loadedSchema = try await backend.loadSchema(profileID: profileID)
      updateWorkspace(for: profileID) { $0.schema = loadedSchema }
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
    connectionWorkspaces.removeValue(forKey: profileID)
    connectingProfileIDs.remove(profileID)
    if selectedConnectionID == profileID {
      selectedConnectionID = connections.first?.id
    }
    do {
      try profileStore.save(connections)
    } catch {
      presentedError = error.localizedDescription
    }
  }

  func runCurrentQuery() async {
    guard !areConnectionOperationsSuspended, let profileID = selectedConnectionID,
      !workspace(for: profileID).isRunning,
      let sql = selectedTab?.sql.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty
    else { return }

    if connections.first(where: { $0.id == profileID })?.status != .connected {
      await connect(profileID: profileID)
      guard connections.first(where: { $0.id == profileID })?.status == .connected else { return }
    }

    updateWorkspace(for: profileID) {
      $0.isRunning = true
      $0.executionMessage = "Running query…"
    }
    do {
      let result = try await backend.execute(profileID: profileID, sql: sql)
      updateWorkspace(for: profileID) {
        $0.queryTable = result.table
        $0.executionMessage =
          result.table.rows.isEmpty
          ? "Query completed · \(result.durationMilliseconds) ms"
          : "\(result.table.rows.count) rows · \(result.durationMilliseconds) ms"
      }
      if sql.localizedCaseInsensitiveContains("CREATE ")
        || sql.localizedCaseInsensitiveContains("ALTER ")
        || sql.localizedCaseInsensitiveContains("DROP ")
      {
        await refreshSchema(profileID: profileID)
      }
    } catch {
      if areConnectionOperationsSuspended {
        updateWorkspace(for: profileID) { $0.executionMessage = "No results" }
      } else {
        updateWorkspace(for: profileID) { $0.executionMessage = "Query failed" }
        presentedError = error.localizedDescription
      }
    }
    updateWorkspace(for: profileID) { $0.isRunning = false }
  }

  func suspendConnections() async {
    resumeRequestedAfterCleanup = false
    activeSuspensionCleanups += 1
    areConnectionOperationsSuspended = true
    connectingProfileIDs = []
    for profileID in Array(connectionWorkspaces.keys) {
      updateWorkspace(for: profileID) {
        $0.schema = .empty
        $0.isRunning = false
        $0.executionMessage = "No results"
      }
    }
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
    updateWorkspace(for: selectedConnectionID) {
      $0.queryTable = .empty
      $0.executionMessage = "No results"
    }
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
    updateWorkspace(for: selectedConnectionID) {
      $0.editorTabs[index].sql = sql
      $0.editorTabs[index].isModified = true
    }
  }

  func useSQL(_ sql: String) {
    guard let selectedTabID,
      let index = editorTabs.firstIndex(where: { $0.id == selectedTabID })
    else { return }
    updateWorkspace(for: selectedConnectionID) {
      $0.editorTabs[index].sql = sql
      $0.editorTabs[index].isModified = true
    }
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

  func mcpSelectedProfile() throws -> ConnectionProfile {
    guard let selectedConnection else { throw MCPAccessError.noSelectedConnection }
    return selectedConnection
  }

  func mcpSchemaSnapshot() async throws -> [SchemaObject] {
    let profile = try requireMCPConnection()
    let snapshot = try await backend.loadSchema(profileID: profile.id)
    updateWorkspace(for: profile.id) { $0.schema = snapshot }
    return snapshot.objects
  }

  func mcpDescribeObject(
    schema: String,
    name: String,
    kind: SchemaObjectKind?
  ) async throws -> SchemaObjectDetails {
    let profile = try requireMCPConnection()
    let objects = try await backend.loadSchema(profileID: profile.id).objects
    guard
      let object = objects.first(where: {
        $0.schema == schema && $0.name == name && (kind == nil || $0.kind == kind)
      })
    else {
      throw MCPAccessError.schemaObjectNotFound
    }
    return try await backend.loadSchemaObjectDetails(profileID: profile.id, object: object)
  }

  func mcpExecuteReadOnlyQuery(sql: String, maximumRows: Int) async throws -> MCPQuerySnapshot {
    let profile = try requireMCPConnection()
    guard profile.effectiveAccessLevel == .readOnly else {
      throw MCPAccessError.readOnlyConnectionRequired
    }
    guard !workspace(for: profile.id).isRunning else {
      throw MCPAccessError.queryAlreadyRunning
    }
    try QuerySafetyPolicy.validate(sql: sql, accessLevel: .readOnly)
    updateWorkspace(for: profile.id) { $0.isRunning = true }
    defer { updateWorkspace(for: profile.id) { $0.isRunning = false } }
    let result = try await backend.execute(profileID: profile.id, sql: sql)
    let rows = result.table.rows.prefix(maximumRows)
    return MCPQuerySnapshot(
      columns: result.table.columns,
      rows: rows.map { $0.map(MCPQueryCell.init) },
      returnedRowCount: rows.count,
      truncated: result.table.rows.count > maximumRows,
      durationMilliseconds: result.durationMilliseconds
    )
  }

  private func requireMCPConnection() throws -> ConnectionProfile {
    guard !areConnectionOperationsSuspended else { throw MCPAccessError.connectionNotReady }
    let profile = try mcpSelectedProfile()
    guard profile.status == .connected else { throw MCPAccessError.connectionNotReady }
    return profile
  }

  private func workspace(for profileID: UUID?) -> ConnectionWorkspace {
    guard let profileID else { return detachedWorkspace }
    return connectionWorkspaces[profileID] ?? detachedWorkspace
  }

  private func ensureWorkspace(for profileID: UUID) {
    if connectionWorkspaces[profileID] == nil {
      connectionWorkspaces[profileID] = ConnectionWorkspace()
    }
  }

  private func updateWorkspace(
    for profileID: UUID?,
    _ update: (inout ConnectionWorkspace) -> Void
  ) {
    guard let profileID else {
      update(&detachedWorkspace)
      return
    }
    var workspace = connectionWorkspaces[profileID] ?? ConnectionWorkspace()
    update(&workspace)
    connectionWorkspaces[profileID] = workspace
  }

  private func apply(_ metadata: ConnectionMetadata, to profile: inout ConnectionProfile) {
    profile.database = metadata.database
    profile.latency = metadata.latencyMilliseconds
    profile.serverVersion = metadata.serverVersion
    profile.serverEncoding = metadata.serverEncoding
    profile.serverTimeZone = metadata.serverTimeZone
  }
}
