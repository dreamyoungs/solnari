import AppKit
import SwiftUI
import Testing

@testable import Solnari

@MainActor
struct FeaturePreviewTests {
  @Test(
    "PostgreSQL 명령 결과를 한국어·영어와 두 테마로 렌더링한다",
    .enabled(
      if: ProcessInfo.processInfo.environment["SOLNARI_RENDER_UI"] != nil
        && ProcessInfo.processInfo.environment["SOLNARI_TEST_POSTGRES_HOST"] == "127.0.0.1"))
  func renderCommandResults() async throws {
    let suiteName = "CommandUI.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profile = ConnectionProfile(
      name: "Local test", database: "postgres", engine: .postgresql,
      transport: .direct, host: "127.0.0.1",
      port: Int(ProcessInfo.processInfo.environment["SOLNARI_TEST_POSTGRES_PORT"] ?? "5432")!,
      username: ProcessInfo.processInfo.environment["SOLNARI_TEST_POSTGRES_USER"] ?? "postgres",
      requiresTLS: false, clientEncoding: "UTF8")
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([profile])
    let model = WorkspaceModel(profileStore: store)
    await model.connect(profileID: profile.id)
    model.useSQL(
      "BEGIN; CREATE TEMP TABLE command_preview(id int); INSERT INTO command_preview VALUES (1); COMMIT;"
    )
    await model.runCurrentQuery()
    #expect(model.executionReport?.transactionState == "committed")
    let settings = AppSettings()
    let original = settings.language
    defer { settings.language = original }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/feature-previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for language in [AppLanguage.korean, .english] {
      settings.language = language
      for dark in [false, true] {
        try await render(
          WorkspaceView().environmentObject(model).environmentObject(settings),
          size: NSSize(width: 1000, height: 800), dark: dark,
          to: output.appendingPathComponent(
            "commands-\(language.rawValue)-\(dark ? "dark" : "light").png"))
      }
    }
    model.useSQL("GRANT SELECT ON command_preview TO PUBLIC;")
    await model.runCurrentQuery()
    #expect(model.executionReport?.commands.first?.tag == "GRANT")
    #expect(model.canVerifyPrivileges)
    await model.verifyPrivileges()
    #expect(model.queryTable.rows.contains { $0.first == .text("+") })
    await model.suspendConnections()
  }

  @Test(
    "한국어·영어 및 밝은·어두운 테마의 실제 SwiftUI 화면을 렌더링한다",
    .enabled(if: ProcessInfo.processInfo.environment["SOLNARI_RENDER_UI"] != nil))
  func renderFeatureScreens() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FeatureUITests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = ConnectionProfile(
      name: "Local demo", database: directory.appendingPathComponent("demo.db").path,
      engine: .sqlite, transport: .direct, host: "", port: 0, username: "", requiresTLS: false,
      clientEncoding: "Automatic")
    let backend = DatabaseBackend()
    _ = try await backend.connect(profile: profile, password: "")
    _ = try await backend.execute(
      profileID: profile.id, sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    _ = try await backend.execute(
      profileID: profile.id, sql: "CREATE VIEW recent_items AS SELECT * FROM items")
    await backend.disconnectAll()
    let suiteName = "FeatureUI.\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([profile])
    let model = WorkspaceModel(backend: backend, profileStore: store)
    await model.connect(profileID: profile.id)
    let settings = AppSettings()
    let originalLanguage = settings.language
    defer { settings.language = originalLanguage }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/feature-previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for language in [AppLanguage.korean, .english] {
      settings.language = language
      for dark in [false, true] {
        let name = "\(language.rawValue)-\(dark ? "dark" : "light")"
        let query = model.editorTabs.first(where: { $0.kind == .query })!
        model.selectedTabID = query.id
        model.useSQL("SELECT id, name\nFROM items\nWHERE id > 1;")
        model.explainCurrentQuery()
        while model.isPlanning { await Task.yield() }
        let content = HStack(spacing: 0) {
          SidebarView().frame(width: 250)
          WorkspaceView()
          AIAssistantView().frame(width: 340)
        }
        .environmentObject(model).environmentObject(settings).environment(\.locale, settings.locale)
        try await render(
          content, size: NSSize(width: 1480, height: 900), dark: dark,
          to: output.appendingPathComponent("plan-\(name).png"))
        let items = model.schemaObjects.first(where: { $0.name == "items" })!
        model.presentSchemaObject(items, pinned: true)
        let second = model.schemaObjects.first(where: { $0.name == "recent_items" })!
        model.presentSchemaObject(second)
        try await render(
          content, size: NSSize(width: 1480, height: 900), dark: dark,
          to: output.appendingPathComponent("schema-\(name).png"))
        let newConnection = NewConnectionView().environmentObject(model).environmentObject(settings)
        try await render(
          newConnection, size: NSSize(width: 720, height: 680), dark: dark,
          to: output.appendingPathComponent("connection-\(name).png"))
      }
    }
    await model.suspendConnections()
  }

  private func render<V: View>(_ content: V, size: NSSize, dark: Bool, to url: URL) async throws {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let view = NSHostingView(rootView: content)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    view.layoutSubtreeIfNeeded()
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    try #require(image.representation(using: .png, properties: [:])).write(to: url)
    #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
  }
}
