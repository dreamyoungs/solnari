import Foundation
import SwiftUI

enum DatabaseEngine: String, CaseIterable, Identifiable, Hashable, Sendable {
  case postgresql = "PostgreSQL"
  case mysql = "MySQL"
  case sqlite = "SQLite"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .postgresql: "cylinder.split.1x2"
    case .mysql: "cylinder"
    case .sqlite: "doc.badge.gearshape"
    }
  }

  var tint: Color {
    switch self {
    case .postgresql: SolnariTheme.indigo
    case .mysql: SolnariTheme.orange
    case .sqlite: SolnariTheme.mint
    }
  }
}

enum ConnectionTransport: String, CaseIterable, Identifiable, Hashable, Sendable {
  case direct = "Direct"
  case cloudSQL = "Cloud SQL"
  case ssh = "SSH Tunnel"
  case kubernetes = "Kubernetes"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .direct: "network"
    case .cloudSQL: "cloud.fill"
    case .ssh: "lock.shield.fill"
    case .kubernetes: "shippingbox.fill"
    }
  }

  var detail: String {
    switch self {
    case .direct: "Connect directly to a host and port"
    case .cloudSQL: "Connect securely with Google IAM"
    case .ssh: "Connect through a bastion host"
    case .kubernetes: "Connect through a kubeconfig context"
    }
  }
}

enum ConnectionStatus: String, Hashable, Sendable {
  case connected = "Connected"
  case sleeping = "Sleeping"
  case disconnected = "Disconnected"

  var color: Color {
    switch self {
    case .connected: SolnariTheme.mint
    case .sleeping: SolnariTheme.orange
    case .disconnected: .secondary
    }
  }
}

struct ConnectionProfile: Identifiable, Hashable, Sendable {
  let id: UUID
  var name: String
  var subtitle: String
  var database: String
  var engine: DatabaseEngine
  var transport: ConnectionTransport
  var status: ConnectionStatus
  var latency: Int?

  init(
    id: UUID = UUID(),
    name: String,
    subtitle: String,
    database: String,
    engine: DatabaseEngine,
    transport: ConnectionTransport,
    status: ConnectionStatus,
    latency: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.subtitle = subtitle
    self.database = database
    self.engine = engine
    self.transport = transport
    self.status = status
    self.latency = latency
  }
}

enum SchemaObjectKind: String, Hashable, Sendable {
  case table
  case view
  case function

  var symbol: String {
    switch self {
    case .table: "tablecells"
    case .view: "eye"
    case .function: "function"
    }
  }
}

struct SchemaObject: Identifiable, Hashable, Sendable {
  let id = UUID()
  let name: String
  let kind: SchemaObjectKind
  let metadata: String
}

struct EditorTab: Identifiable, Hashable, Sendable {
  let id: UUID
  var title: String
  var sql: String
  var isModified: Bool

  init(id: UUID = UUID(), title: String, sql: String, isModified: Bool = false) {
    self.id = id
    self.title = title
    self.sql = sql
    self.isModified = isModified
  }
}

struct QueryRow: Identifiable, Hashable, Sendable {
  let id: Int
  let name: String
  let email: String
  let plan: String
  let orders: Int
  let revenue: String
  let createdAt: String
}

enum MessageRole: Hashable, Sendable {
  case user
  case assistant
}

struct AssistantMessage: Identifiable, Hashable, Sendable {
  let id = UUID()
  let role: MessageRole
  let text: String
  let sql: String?
}

struct ConnectionDraft: Sendable {
  var name = ""
  var engine: DatabaseEngine = .postgresql
  var transport: ConnectionTransport = .direct
  var host = "localhost"
  var port = "5432"
  var database = ""
  var user = ""
  var password = ""
  var cloudProject = "cloudturing-prod"
  var cloudInstance = "production-postgres"
  var useIAM = true
  var sshHost = ""
  var kubeContext = "nks_kr_public-prod"
  var namespace = "db-access"
  var clientEncoding = "Automatic"
  var preferredCharacterSet = "Database default"
  var preferredCollation = "Database default"
  var auditTextSettings = true
}

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published var connections: [ConnectionProfile]
  @Published var selectedConnectionID: UUID?
  @Published var schemaObjects: [SchemaObject]
  @Published var editorTabs: [EditorTab]
  @Published var selectedTabID: UUID?
  @Published var queryRows: [QueryRow]
  @Published var assistantMessages: [AssistantMessage]
  @Published var assistantDraft = ""
  @Published var isAssistantVisible = true
  @Published var isRunning = false
  @Published var executionMessage = "8 rows · 42 ms"
  @Published var showNewConnection = false
  @Published var selectedResultTab = "Results"

  init() {
    let production = ConnectionProfile(
      name: "Production",
      subtitle: "asia-northeast3 · Cloud SQL",
      database: "app_production",
      engine: .postgresql,
      transport: .cloudSQL,
      status: .connected,
      latency: 28
    )
    let analytics = ConnectionProfile(
      name: "Analytics",
      subtitle: "nks-prod · db-access",
      database: "warehouse",
      engine: .postgresql,
      transport: .kubernetes,
      status: .sleeping
    )
    let local = ConnectionProfile(
      name: "Local development",
      subtitle: "localhost:5432",
      database: "solnari_dev",
      engine: .postgresql,
      transport: .direct,
      status: .disconnected
    )

    let overview = EditorTab(
      title: "Customer overview",
      sql: """
        SELECT
          u.id,
          u.name,
          u.email,
          u.plan,
          COUNT(o.id) AS orders,
          COALESCE(SUM(o.amount), 0) AS revenue,
          u.created_at
        FROM public.users AS u
        LEFT JOIN public.orders AS o ON o.user_id = u.id
        WHERE u.created_at >= CURRENT_DATE - INTERVAL '30 days'
        GROUP BY u.id
        ORDER BY revenue DESC
        LIMIT 100;
        """
    )
    let scratch = EditorTab(title: "Scratch 2", sql: "SELECT NOW();")

    connections = [production, analytics, local]
    selectedConnectionID = production.id
    schemaObjects = [
      SchemaObject(name: "users", kind: .table, metadata: "24 columns"),
      SchemaObject(name: "orders", kind: .table, metadata: "18 columns"),
      SchemaObject(name: "order_items", kind: .table, metadata: "9 columns"),
      SchemaObject(name: "subscriptions", kind: .table, metadata: "14 columns"),
      SchemaObject(name: "active_customers", kind: .view, metadata: "view"),
      SchemaObject(name: "monthly_revenue", kind: .view, metadata: "materialized"),
    ]
    editorTabs = [overview, scratch]
    selectedTabID = overview.id
    queryRows = Self.sampleRows
    assistantMessages = [
      AssistantMessage(
        role: .assistant,
        text: "I’ve read the schema. I can explain queries or suggest safer and faster SQL.",
        sql: nil
      ),
      AssistantMessage(
        role: .user,
        text: "Show the order totals for new customers from the last 30 days, highest first.",
        sql: nil
      ),
      AssistantMessage(
        role: .assistant,
        text:
          "I joined users and orders, then aggregated by customer. This is read-only and limited to 100 rows.",
        sql: overview.sql
      ),
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

  func runCurrentQuery() async {
    guard !isRunning else { return }
    isRunning = true
    executionMessage = "Running query…"
    try? await Task.sleep(for: .milliseconds(520))
    queryRows = Self.sampleRows
    executionMessage = "8 rows · 42 ms"
    isRunning = false
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
        sql:
          "SELECT plan, COUNT(*) AS customers\nFROM public.users\nGROUP BY plan\nORDER BY customers DESC;"
      )
    )
  }

  func addConnection(_ draft: ConnectionDraft) {
    let profile = ConnectionProfile(
      name: draft.name.isEmpty ? "New connection" : draft.name,
      subtitle: draft.transport == .cloudSQL
        ? "\(draft.cloudProject) · \(draft.cloudInstance)" : draft.host,
      database: draft.database.isEmpty ? "default" : draft.database,
      engine: draft.engine,
      transport: draft.transport,
      status: .connected,
      latency: 34
    )
    connections.insert(profile, at: 0)
    selectedConnectionID = profile.id
  }

  static let sampleRows = [
    QueryRow(
      id: 1042, name: "Minseo Kim", email: "minseo@example.com", plan: "Business", orders: 18,
      revenue: "$12,480", createdAt: "2026-08-03 09:42"),
    QueryRow(
      id: 1068, name: "Jiwon Lee", email: "jiwon@example.com", plan: "Pro", orders: 11,
      revenue: "$8,920", createdAt: "2026-08-07 14:18"),
    QueryRow(
      id: 1091, name: "Hyunwoo Park", email: "hyunwoo@example.com", plan: "Business", orders: 9,
      revenue: "$7,640", createdAt: "2026-08-12 11:03"),
    QueryRow(
      id: 1114, name: "Yuna Choi", email: "yuna@example.com", plan: "Pro", orders: 8,
      revenue: "$5,380", createdAt: "2026-08-16 17:25"),
    QueryRow(
      id: 1127, name: "Seojun Han", email: "seojun@example.com", plan: "Starter", orders: 6,
      revenue: "$2,940", createdAt: "2026-08-19 08:51"),
    QueryRow(
      id: 1140, name: "Sohui Jung", email: "sohui@example.com", plan: "Pro", orders: 5,
      revenue: "$2,210", createdAt: "2026-08-21 16:34"),
    QueryRow(
      id: 1156, name: "Doyun Lim", email: "doyun@example.com", plan: "Starter", orders: 3,
      revenue: "$1,180", createdAt: "2026-08-25 10:07"),
    QueryRow(
      id: 1172, name: "Haeun Song", email: "haeun@example.com", plan: "Free", orders: 1,
      revenue: "$240", createdAt: "2026-08-28 13:46"),
  ]

  var queryTable: QueryTableData {
    QueryTableData(
      columns: ["id", "name", "email", "plan", "orders", "revenue", "created_at"],
      rows: queryRows.map { row in
        [
          .integer(row.id),
          .text(row.name),
          .text(row.email),
          .text(row.plan),
          .integer(row.orders),
          .text(row.revenue),
          .text(row.createdAt),
        ]
      }
    )
  }
}
