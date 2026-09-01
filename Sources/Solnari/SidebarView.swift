import AppKit
import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.openSettings) private var openSettings
  @State private var searchText = ""
  @State private var schemasExpanded = true
  @State private var schemaExpansion: [String: Bool] = [:]
  @State private var objectGroupExpansion: [String: Bool] = [:]
  @State private var connectionPendingRemoval: ConnectionProfile?

  private var filteredConnections: [ConnectionProfile] {
    guard !searchText.isEmpty else { return model.connections }
    return model.connections.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || $0.database.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      brandHeader

      List(selection: $model.selectedConnectionID) {
        Section {
          ForEach(filteredConnections) { connection in
            ConnectionRow(
              connection: connection,
              onConnect: { Task { await model.connect(profileID: connection.id) } },
              onEdit: { model.beginEditingConnection(connection.id) },
              onRemove: { connectionPendingRemoval = connection }
            )
            .tag(connection.id)
            .contextMenu {
              Button(settings.text("Connect")) {
                Task { await model.connect(profileID: connection.id) }
              }
              Button(settings.text("Edit…")) {
                model.beginEditingConnection(connection.id)
              }
              Divider()
              Button(settings.text("Remove"), role: .destructive) {
                connectionPendingRemoval = connection
              }
            }
          }
        } header: {
          sectionHeader("Connections", count: filteredConnections.count) {
            model.beginNewConnection()
          }
        }

        if let connection = model.selectedConnection {
          Section {
            databaseTree(connection)
          } header: {
            sectionHeader("Explorer", count: nil) {}
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .searchable(
        text: $searchText, placement: .sidebar, prompt: Text(settings.text("Connections")))

      sidebarFooter
    }
    .background(SolnariTheme.sidebar)
    .confirmationDialog(
      settings.text("Remove connection?"),
      isPresented: Binding(
        get: { connectionPendingRemoval != nil },
        set: { if !$0 { connectionPendingRemoval = nil } }
      ),
      titleVisibility: .visible,
      presenting: connectionPendingRemoval
    ) { connection in
      Button(settings.text("Remove"), role: .destructive) {
        connectionPendingRemoval = nil
        Task { await model.removeConnection(connection.id) }
      }
      Button(settings.text("Cancel"), role: .cancel) {
        connectionPendingRemoval = nil
      }
    } message: { connection in
      Text(
        String(
          format: settings.text("Remove “%@” and its saved local credentials?"),
          connection.name
        )
      )
    }
  }

  private var brandHeader: some View {
    HStack(spacing: 11) {
      SolnariMark(size: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text("Solnari")
          .font(.system(size: 16, weight: .bold, design: .rounded))
        Text(settings.text("Database workspace"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 13)
    .padding(.bottom, 10)
  }

  private func sectionHeader(_ title: String, count: Int?, action: @escaping () -> Void)
    -> some View
  {
    HStack {
      Text(settings.text(title))
      if let count {
        Text("\(count)")
          .foregroundStyle(.tertiary)
      }
      Spacer()
      if title == "Connections" {
        Button(action: action) {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help(settings.text("New connection"))
      }
    }
  }

  @ViewBuilder
  private func databaseTree(_ connection: ConnectionProfile) -> some View {
    DisclosureGroup(isExpanded: $schemasExpanded) {
      if schemaNames.isEmpty {
        Text(settings.text("No schema objects"))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(schemaNames, id: \.self) { schema in
          schemaTree(schema)
        }
      }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "cylinder")
          .foregroundStyle(connection.engine.tint)
        Text(connection.database)
          .fontWeight(.medium)
        Spacer()
        Button {
          Task { await model.refreshSchema() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var schemaNames: [String] {
    Array(Set(model.schemaObjects.map(\.schema))).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }

  private func schemaTree(_ schema: String) -> some View {
    let objects = model.schemaObjects.filter { $0.schema == schema }
    let tables = objects.filter { $0.kind == .table }
    let views = objects.filter { $0.kind == .view || $0.kind == .materializedView }
    return DisclosureGroup(
      isExpanded: expansionBinding(
        key: schema,
        storage: $schemaExpansion,
        defaultValue: schema == "public" || schema == "main" || schemaNames.count == 1
      )
    ) {
      if !tables.isEmpty {
        objectGroup("Tables", symbol: "tablecells", schema: schema, objects: tables)
      }
      if !views.isEmpty {
        objectGroup("Views", symbol: "eye", schema: schema, objects: views)
      }
    } label: {
      treeLabel(schema, symbol: "square.3.layers.3d", count: objects.count, localize: false)
    }
  }

  private func objectGroup(
    _ title: String,
    symbol: String,
    schema: String,
    objects: [SchemaObject]
  ) -> some View {
    DisclosureGroup(
      isExpanded: expansionBinding(
        key: "\(schema).\(title)",
        storage: $objectGroupExpansion,
        defaultValue: true
      )
    ) {
      ForEach(objects) { object in
        SchemaObjectRow(object: object)
      }
    } label: {
      treeLabel(title, symbol: symbol, count: objects.count)
    }
  }

  private func expansionBinding(
    key: String,
    storage: Binding<[String: Bool]>,
    defaultValue: Bool
  ) -> Binding<Bool> {
    Binding(
      get: { storage.wrappedValue[key] ?? defaultValue },
      set: { storage.wrappedValue[key] = $0 }
    )
  }

  private func treeLabel(
    _ title: String,
    symbol: String,
    count: Int,
    localize: Bool = true
  ) -> some View {
    HStack(spacing: 7) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 15)
      Text(localize ? settings.text(title) : title)
      Spacer()
      Text("\(count)")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var sidebarFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(SolnariTheme.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text(settings.text("Codex preview"))
          .font(.caption.weight(.medium))
        Text(settings.text("Integration planned"))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(SolnariTheme.sidebarElevated)
    .overlay(alignment: .top) { Divider() }
  }
}

private struct ConnectionRow: View {
  @EnvironmentObject private var settings: AppSettings
  let connection: ConnectionProfile
  let onConnect: () -> Void
  let onEdit: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(connection.engine.tint.opacity(0.12))
          .frame(width: 31, height: 31)
          .overlay {
            Image(systemName: connection.engine.symbol)
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(connection.engine.tint)
          }
        StatusDot(color: connection.status.color, size: 6)
          .background(SolnariTheme.sidebar, in: Circle())
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(connection.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Text(connection.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: connection.transport.symbol)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Menu {
        Button(settings.text("Connect"), action: onConnect)
        Button(settings.text("Edit…"), action: onEdit)
        Divider()
        Button(settings.text("Remove"), role: .destructive, action: onRemove)
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 18, height: 18)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(settings.text("Connection actions"))
    }
    .padding(.vertical, 3)
  }
}

private struct SchemaObjectRow: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  let object: SchemaObject

  var body: some View {
    Button {
      model.presentSchemaObject(object)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: object.kind.symbol)
          .font(.caption)
          .foregroundStyle(object.kind == .view ? SolnariTheme.orange : .secondary)
          .frame(width: 15)
        Text(object.name)
          .font(.system(size: 12))
        Spacer()
        Text(localizedMetadata)
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(settings.text("View structure")) {
        model.presentSchemaObject(object)
      }
      Button(settings.text("Open data")) {
        Task { await model.openData(for: object) }
      }
      Divider()
      Button(settings.text("Copy qualified name")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(object.qualifiedName, forType: .string)
      }
      Button(settings.text("Generate SELECT")) {
        model.generateSelect(for: object)
      }
    }
  }

  private var localizedMetadata: String {
    if object.metadata.hasSuffix(" columns"),
      let count = object.metadata.split(separator: " ").first
    {
      return settings.effectiveLanguage == .korean ? "\(count)개 컬럼" : object.metadata
    }
    return settings.text(object.metadata)
  }
}
